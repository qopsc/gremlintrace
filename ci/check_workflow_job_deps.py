#!/usr/bin/env python3
"""Verify workflow jobs install every third-party Python import their scripts need."""
from __future__ import annotations

import argparse
import ast
import re
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS_DIR = REPO_ROOT / ".github" / "workflows"

# Imports that require an explicit `pip install` line in the same job.
THIRD_PARTY_IMPORTS = frozenset({"yaml"})

SCRIPT_REF_RE = re.compile(
    r"(?:^|[\s\"'])"
    r"(?:\./)?((?:ci|e2b/build)/[\w./-]+\.(?:sh|py))"
)
PYTHON_CI_RE = re.compile(r"python3\s+(?:\$\{REPO_ROOT\}/|)?(ci/[\w.-]+\.py)")
INLINE_PYTHON_RE = re.compile(r"python3\s+-c\s+((?:'[^']*'|\"[^\"]*\"))", re.DOTALL)


def extract_script_refs(run_text: str) -> list[str]:
    refs: list[str] = []
    for line in run_text.splitlines():
        for match in SCRIPT_REF_RE.finditer(line):
            refs.append(match.group(1))
        for match in PYTHON_CI_RE.finditer(line):
            refs.append(match.group(1))
    return refs


def pip_imports_provided(run_text: str) -> set[str]:
    provided: set[str] = set()
    if re.search(r"pip\s+install[^\n]*\bpyyaml\b", run_text, re.IGNORECASE):
        provided.add("yaml")
    if re.search(r"pip\s+install[^\n]*\bPyYAML\b", run_text):
        provided.add("yaml")
    return provided


def job_pip_imports(steps: list[dict]) -> set[str]:
    provided: set[str] = set()
    for step in steps:
        run = step.get("run")
        if isinstance(run, str):
            provided |= pip_imports_provided(run)
    return provided


def imports_from_python(path: Path) -> set[str]:
    tree = ast.parse(path.read_text(encoding="utf-8"))
    mods: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                mods.add(alias.name.split(".")[0])
        elif isinstance(node, ast.ImportFrom) and node.module:
            mods.add(node.module.split(".")[0])
    return mods


def inline_python_imports(shell_path: Path) -> set[str]:
    text = shell_path.read_text(encoding="utf-8")
    mods: set[str] = set()
    for match in INLINE_PYTHON_RE.finditer(text):
        code = match.group(1)[1:-1]
        try:
            tree = ast.parse(code)
        except SyntaxError:
            continue
        mods |= imports_from_python_source(tree)
    return mods


def imports_from_python_source(tree: ast.AST) -> set[str]:
    mods: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                mods.add(alias.name.split(".")[0])
        elif isinstance(node, ast.ImportFrom) and node.module:
            mods.add(node.module.split(".")[0])
    return mods


def transitive_python_files(entry: Path, seen: set[Path] | None = None) -> set[Path]:
    if seen is None:
        seen = set()
    if not entry.exists() or entry in seen:
        return seen
    seen.add(entry)
    if entry.suffix == ".py":
        text = entry.read_text(encoding="utf-8")
        if "yaml_versions" in text:
            helper = REPO_ROOT / "ci" / "yaml_versions.py"
            if helper.exists():
                transitive_python_files(helper, seen)
        return seen
    if entry.suffix == ".sh":
        text = entry.read_text(encoding="utf-8")
        if "yaml_versions.py" in text:
            transitive_python_files(REPO_ROOT / "ci" / "yaml_versions.py", seen)
        for match in re.finditer(
            r"python3\s+(?:\"\$\{REPO_ROOT\}/|\$\{REPO_ROOT\}/)?(ci/[\w.-]+\.py)",
            text,
        ):
            transitive_python_files(REPO_ROOT / match.group(1), seen)
    return seen


def third_party_imports_for_script(script_rel: str) -> set[str]:
    path = REPO_ROOT / script_rel
    mods: set[str] = set()
    for py_file in transitive_python_files(path):
        if py_file.suffix != ".py":
            continue
        mods |= imports_from_python(py_file)
    if path.suffix == ".sh" and path.exists():
        mods |= inline_python_imports(path)
    return mods & THIRD_PARTY_IMPORTS


def check_workflows(
    workflows_dir: Path,
    extra_scripts: dict[str, dict[str, list[str]]] | None = None,
) -> list[str]:
    """extra_scripts: {workflow_file: {job_id: [script_rel, ...]}}"""
    errors: list[str] = []
    for workflow_path in sorted(workflows_dir.glob("*.yml")):
        workflow = yaml.safe_load(workflow_path.read_text(encoding="utf-8"))
        for job_id, job in workflow.get("jobs", {}).items():
            steps = job.get("steps", [])
            provided = job_pip_imports(steps)
            script_refs: list[str] = []
            for step in steps:
                run = step.get("run")
                if isinstance(run, str):
                    script_refs.extend(extract_script_refs(run))
            if extra_scripts and workflow_path.name in extra_scripts:
                script_refs.extend(extra_scripts[workflow_path.name].get(job_id, []))
            for script_rel in sorted(set(script_refs)):
                needed = third_party_imports_for_script(script_rel)
                missing = needed - provided
                for mod in sorted(missing):
                    errors.append(
                        f"{workflow_path.name}:{job_id}: {script_rel} imports {mod} "
                        f"but job provides pip imports {sorted(provided) or '(none)'}"
                    )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--workflows-dir",
        type=Path,
        default=WORKFLOWS_DIR,
    )
    parser.add_argument(
        "--inject",
        action="append",
        metavar="WORKFLOW:JOB:SCRIPT",
        help="Add a script reference to a job for testing (e.g. build-e2b.yml:build-dist:ci/bad.py)",
    )
    args = parser.parse_args()

    extra: dict[str, dict[str, list[str]]] = {}
    if args.inject:
        for item in args.inject:
            wf, job, script = item.split(":", 2)
            extra.setdefault(wf, {}).setdefault(job, []).append(script)

    errors = check_workflows(args.workflows_dir, extra or None)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
