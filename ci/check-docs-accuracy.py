#!/usr/bin/env python3
"""Verify documentation references exist in the repository."""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

DOC_PATHS = [
    REPO_ROOT / "README.md",
    REPO_ROOT / "docs" / "architecture.md",
    REPO_ROOT / "docs" / "install.md",
    REPO_ROOT / "docs" / "operations.md",
    REPO_ROOT / "docs" / "security.md",
    REPO_ROOT / "docs" / "spike-notes.md",
    REPO_ROOT / "docs" / "distro-notes" / "ubuntu-24.04.md",
    REPO_ROOT / "ci" / "README.md",
]

PLAYBOOK_RE = re.compile(r"ansible/playbooks/([a-z0-9_-]+)\.yml")
ROLE_RE = re.compile(r"ansible/roles/([a-z0-9_]+)(?:/|`)")
CI_SCRIPT_RE = re.compile(r"ci/matrix/([a-z0-9_-]+\.sh)")
BOOTSTRAP_RE = re.compile(r"(?<![\w./])bootstrap\.sh(?![\w.-])")
WORKFLOW_RE = re.compile(r"\.github/workflows/([a-z0-9_-]+)\.yml")
QOPS_BIN_RE = re.compile(r"/usr/local/bin/(qops-[a-z0-9_-]+)")
QOPS_LIB_RE = re.compile(r"/usr/local/lib/qops/([a-z0-9_.-]+)")

# Playbooks referenced as `./bootstrap.sh --playbook <name>` or `playbook <name>`.
PLAYBOOK_NAME_RE = re.compile(
    r"(?:--playbook\s+|playbooks/)([a-z0-9_-]+)(?:\.yml)?"
)


def collect_docs(inject_bad: str | None) -> list[Path]:
    docs = [p for p in DOC_PATHS if p.is_file()]
    if inject_bad:
        target = REPO_ROOT / "docs" / ".docs-accuracy-inject.md"
        target.write_text(
            f"# inject\n\nSee ansible/playbooks/{inject_bad}.yml for details.\n",
            encoding="utf-8",
        )
        docs.append(target)
    return docs


def qops_script_sources() -> set[str]:
    names: set[str] = set()
    for path in (REPO_ROOT / "ansible" / "roles").rglob("files/*"):
        if path.is_file():
            names.add(path.name)
    return names


def check_docs(inject_bad: str | None = None) -> list[str]:
    errors: list[str] = []
    playbooks_dir = REPO_ROOT / "ansible" / "playbooks"
    roles_dir = REPO_ROOT / "ansible" / "roles"
    workflows_dir = REPO_ROOT / ".github" / "workflows"
    ci_matrix_dir = REPO_ROOT / "ci" / "matrix"
    qops_files = qops_script_sources()

    for doc in collect_docs(inject_bad):
        text = doc.read_text(encoding="utf-8")
        rel = doc.relative_to(REPO_ROOT)

        for match in PLAYBOOK_RE.finditer(text):
            name = match.group(1)
            path = playbooks_dir / f"{name}.yml"
            if not path.is_file():
                errors.append(f"{rel}: missing playbook ansible/playbooks/{name}.yml")

        for match in PLAYBOOK_NAME_RE.finditer(text):
            name = match.group(1)
            if name in {"site", "doctor", "upgrade", "preflight", "uninstall", "backup", "restore"}:
                path = playbooks_dir / f"{name}.yml"
                if not path.is_file():
                    errors.append(f"{rel}: missing playbook {name}.yml")

        for match in ROLE_RE.finditer(text):
            name = match.group(1)
            if not (roles_dir / name).is_dir():
                errors.append(f"{rel}: missing role ansible/roles/{name}/")

        for match in CI_SCRIPT_RE.finditer(text):
            script = match.group(1)
            if not (ci_matrix_dir / script).is_file():
                errors.append(f"{rel}: missing ci/matrix/{script}")

        if BOOTSTRAP_RE.search(text) and not (REPO_ROOT / "bootstrap.sh").is_file():
            errors.append(f"{rel}: bootstrap.sh not found")

        for match in WORKFLOW_RE.finditer(text):
            wf = match.group(1)
            if not (workflows_dir / f"{wf}.yml").is_file():
                errors.append(f"{rel}: missing workflow .github/workflows/{wf}.yml")

        for match in QOPS_BIN_RE.finditer(text):
            script = match.group(1)
            if script not in qops_files:
                errors.append(f"{rel}: no role file for /usr/local/bin/{script}")

        for match in QOPS_LIB_RE.finditer(text):
            script = match.group(1)
            if script not in qops_files:
                errors.append(f"{rel}: no role file for /usr/local/lib/qops/{script}")

    inject_path = REPO_ROOT / "docs" / ".docs-accuracy-inject.md"
    if inject_path.is_file() and inject_bad is None:
        inject_path.unlink()

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--inject-bad-playbook",
        metavar="NAME",
        help="Append a doc referencing a non-existent playbook (test hook).",
    )
    args = parser.parse_args()

    errors = check_docs(inject_bad=args.inject_bad_playbook)
    inject_path = REPO_ROOT / "docs" / ".docs-accuracy-inject.md"
    if inject_path.is_file():
        inject_path.unlink()

    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
