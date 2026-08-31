#!/usr/bin/env python3
"""Render every task-5/6 role template using production defaults only."""
from __future__ import annotations

import os
import pathlib
import subprocess
import sys
import tempfile

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
ROLES = ("preflight", "common", "host_firewall", "docker", "e2b_host", "e2b_datastores")


def merge_production_defaults() -> dict:
    merged: dict = {}
    for path in (ROOT / "versions.yml", ROOT / "ansible/group_vars/all.yml"):
        merged.update(yaml.safe_load(path.read_text()) or {})
    for role in ROLES:
        defaults = ROOT / f"ansible/roles/{role}/defaults/main.yml"
        if defaults.is_file():
            merged.update(yaml.safe_load(defaults.read_text()) or {})
    return merged


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
    vars_path.unlink(missing_ok=True)

    if errors:
        for err in errors:
            print(err, file=sys.stderr)
        return 1

    template_count = sum(
        len(list((ROOT / f"ansible/roles/{role}/templates").glob("*.j2")))
        for role in ROLES
        if (ROOT / f"ansible/roles/{role}/templates").is_dir()
    )
    print(f"ok: rendered {template_count} templates with production defaults")
    return 0


if __name__ == "__main__":
    sys.exit(main())
