#!/usr/bin/env python3
"""Render role templates and validate task variables against production defaults."""
from __future__ import annotations

import os
import pathlib
import re
import subprocess
import sys
import tempfile

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
ROLES = ("preflight", "common", "host_firewall", "docker", "e2b_host", "e2b_datastores")

JINJA_BLOCK = re.compile(r"\{\{-?(.+?)-?\}\}|\{%-?(.+?)-?\%\}", re.DOTALL)
IDENT = re.compile(r"\b([a-zA-Z_][a-zA-Z0-9_]*)\b")

# Ansible/Jinja builtins, filters, tests, and common functions — not role variables.
IGNORED_NAMES = frozenset(
    {
        "true",
        "false",
        "none",
        "True",
        "False",
        "None",
        "item",
        "ansible_loop",
        "omit",
        "vars",
        "hostvars",
        "groups",
        "group_names",
        "play_hosts",
        "inventory_hostname",
        "role_path",
        "playbook_dir",
        "ansible_play_hosts",
        "ansible_play_hosts_all",
        "ansible_check_mode",
        "ansible_diff_mode",
        "ansible_version",
        "ansible_facts",
        "lookup",
        "query",
        "env",
        "from_json",
        "to_json",
        "b64decode",
        "join",
        "trim",
        "default",
        "length",
        "bool",
        "int",
        "string",
        "map",
        "select",
        "reject",
        "list",
        "dict",
        "zip",
        "first",
        "last",
        "unique",
        "flatten",
        "combine",
        "product",
        "split",
        "regex_search",
        "regex_replace",
        "regex_escape",
        "dirname",
        "basename",
        "ternary",
        "mandatory",
        "quote",
        "lower",
        "upper",
        "abs",
        "min",
        "max",
        "sum",
        "sort",
        "reverse",
        "in",
        "defined",
        "undefined",
        "changed",
        "failed",
        "skipped",
        "stdout",
        "stderr",
        "rc",
        "stat",
        "content",
        "exists",
        "passed",
        "failures",
        "checks",
        "amd64",
        "stable",
        "Debian",
        "RedHat",
        "present",
        "absent",
        "started",
        "stopped",
        "directory",
        "file",
        "touch",
        "running",
        "e2b",
        "postgres",
        "clickhouse",
        "redis",
        "tcp",
        "http",
        "https",
        "deb",
        "arch",
        "signed",
        "by",
        "if",
        "else",
        "elif",
        "endif",
        "for",
        "endfor",
        "not",
        "and",
        "or",
        "is",
        "in",
        "set",
        "endset",
        "when",
        "block",
        "endblock",
        "do",
        "enddo",
        "with",
        "without",
        "ignore",
        "missing",
    }
)


def merge_production_defaults() -> dict:
    merged: dict = {}
    for path in (ROOT / "versions.yml", ROOT / "ansible/group_vars/all.yml"):
        merged.update(yaml.safe_load(path.read_text()) or {})
    for role in ROLES:
        defaults = ROOT / f"ansible/roles/{role}/defaults/main.yml"
        if defaults.is_file():
            merged.update(yaml.safe_load(defaults.read_text()) or {})
    return merged


def yaml_files_under(role: str, subdir: str) -> list[pathlib.Path]:
    base = ROOT / f"ansible/roles/{role}/{subdir}"
    if not base.is_dir():
        return []
    return sorted(base.rglob("*.yml"))


def collect_set_fact_keys(doc: object, keys: set[str]) -> None:
    if isinstance(doc, dict):
        if "ansible.builtin.set_fact" in doc or "set_fact" in doc:
            fact_block = doc.get("ansible.builtin.set_fact") or doc.get("set_fact")
            if isinstance(fact_block, dict):
                keys.update(fact_block.keys())
        for value in doc.values():
            collect_set_fact_keys(value, keys)
    elif isinstance(doc, list):
        for item in doc:
            collect_set_fact_keys(item, keys)


def collect_registered_vars(doc: object, names: set[str]) -> None:
    if isinstance(doc, dict):
        if "register" in doc and isinstance(doc["register"], str):
            names.add(doc["register"])
        if "loop_control" in doc and isinstance(doc["loop_control"], dict):
            loop_var = doc["loop_control"].get("loop_var")
            if isinstance(loop_var, str):
                names.add(loop_var)
        for value in doc.values():
            collect_registered_vars(value, names)
    elif isinstance(doc, list):
        for item in doc:
            collect_registered_vars(item, names)


def strip_string_literals(text: str) -> str:
    text = re.sub(r"'[^']*'", " ", text)
    text = re.sub(r'"[^"]*"', " ", text)
    return text


def refs_in_text(text: str) -> set[str]:
    refs: set[str] = set()
    for match in JINJA_BLOCK.finditer(text):
        expr = match.group(1) or match.group(2) or ""
        expr = strip_string_literals(expr)
        expr = re.sub(r"\.([a-zA-Z_][a-zA-Z0-9_]*)", "", expr)
        for ident in IDENT.findall(expr):
            if ident.startswith("ansible_"):
                continue
            if ident in IGNORED_NAMES:
                continue
            refs.add(ident)
    return refs


def refs_in_yaml_file(path: pathlib.Path) -> set[str]:
    raw = path.read_text()
    refs = refs_in_text(raw)
    try:
        doc = yaml.safe_load(raw)
    except yaml.YAMLError:
        return refs
    set_fact_keys: set[str] = set()
    registered: set[str] = set()
    collect_set_fact_keys(doc, set_fact_keys)
    collect_registered_vars(doc, registered)
    refs -= set_fact_keys
    refs -= registered
    return refs


def collect_task_variable_refs() -> set[str]:
    refs: set[str] = set()
    for role in ROLES:
        for subdir in ("tasks", "handlers", "meta"):
            for path in yaml_files_under(role, subdir):
                refs |= refs_in_yaml_file(path)
    return refs


def unresolved_task_variables(merged: dict) -> list[str]:
    refs = collect_task_variable_refs()
    known = set(merged.keys())
    missing = sorted(name for name in refs if name not in known)
    return missing


def render_templates(vars_path: pathlib.Path) -> list[str]:
    errors: list[str] = []
    env = os.environ.copy()
    env["ANSIBLE_CONFIG"] = str(ROOT / "ansible.cfg")
    env["ANSIBLE_ROLES_PATH"] = str(ROOT / "ansible/roles")

    for role in ROLES:
        template_dir = ROOT / f"ansible/roles/{role}/templates"
        if not template_dir.is_dir():
            continue
        for template in sorted(template_dir.glob("*.j2")):
            if template.name == "secrets.env.j2":
                continue
            dest = tempfile.mktemp()
            cmd = [
                "ansible",
                "localhost",
                "-c",
                "local",
                "-m",
                "ansible.builtin.template",
                "-a",
                f"src={template} dest={dest}",
                "-e",
                f"@{vars_path}",
            ]
            result = subprocess.run(cmd, capture_output=True, text=True, env=env, cwd=ROOT)
            if result.returncode != 0:
                errors.append(
                    f"{template.relative_to(ROOT)}: {result.stderr.strip() or result.stdout.strip()}"
                )
    return errors


def main() -> int:
    merged = merge_production_defaults()
    with tempfile.NamedTemporaryFile("w", suffix=".yml", delete=False) as handle:
        yaml.safe_dump(merged, handle, default_flow_style=False)
        vars_path = pathlib.Path(handle.name)

    errors = render_templates(vars_path)
    missing = unresolved_task_variables(merged)
    vars_path.unlink(missing_ok=True)

    if missing:
        for name in missing:
            errors.append(f"unresolved task variable (no production default): {name}")

    if errors:
        for err in errors:
            print(err, file=sys.stderr)
        return 1

    template_count = sum(
        len(list((ROOT / f"ansible/roles/{role}/templates").glob("*.j2")))
        for role in ROLES
        if (ROOT / f"ansible/roles/{role}/templates").is_dir()
    )
    task_refs = len(collect_task_variable_refs())
    print(
        f"ok: rendered {template_count} templates; "
        f"validated {task_refs} task/handler/meta variable references with production defaults"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
