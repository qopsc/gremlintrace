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

UNCHECKED_GATE_RE = re.compile(r"^- \[ \]", re.M)
UBUNTU_SUPPORTED_RE = re.compile(
    r"Ubuntu\s+24\.04.{0,240}Supported|Supported.{0,240}Ubuntu\s+24\.04",
    re.I | re.S,
)
PHASE0_PASSED_RE = re.compile(
    r"Phase 0.{0,120}(passed|complete|done)|Phase 0 complete",
    re.I | re.S,
)


def collect_docs(inject_bad: str | None, inject_phase0: bool) -> list[Path]:
    docs = [p for p in DOC_PATHS if p.is_file()]
    target = REPO_ROOT / "docs" / ".docs-accuracy-inject.md"
    if inject_bad:
        target.write_text(
            f"# inject\n\nSee ansible/playbooks/{inject_bad}.yml for details.\n",
            encoding="utf-8",
        )
        docs.append(target)
    elif inject_phase0:
        target.write_text(
            "# inject\n\n"
            "Phase 0 complete. Phase 0 has passed on nested virt.\n"
            "Ubuntu 24.04 is Supported as a production distro.\n",
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


def check_honesty(doc: Path, text: str) -> list[str]:
    errors: list[str] = []
    rel = doc.relative_to(REPO_ROOT)
    if doc.name == "spike-notes.md":
        if not UNCHECKED_GATE_RE.search(text):
            errors.append(
                f"{rel}: spike-notes.md must still contain unchecked Phase 0 "
                "gates as `- [ ]` items"
            )
    if UBUNTU_SUPPORTED_RE.search(text):
        errors.append(
            f"{rel}: docs must not call Ubuntu 24.04 'Supported' "
            "(implemented target, unverified)"
        )
    if PHASE0_PASSED_RE.search(text) and "not been executed" not in text.lower():
        errors.append(f"{rel}: docs must not claim Phase 0 passed or complete")
    if inject_claim(text):
        errors.append(f"{rel}: fabricated Phase 0 complete / Ubuntu Supported claim")
    return errors


def inject_claim(text: str) -> bool:
    lower = text.lower()
    return "phase 0 complete" in lower and "ubuntu 24.04 is supported" in lower


def check_docs(
    inject_bad: str | None = None,
    inject_phase0: bool = False,
) -> list[str]:
    errors: list[str] = []
    playbooks_dir = REPO_ROOT / "ansible" / "playbooks"
    roles_dir = REPO_ROOT / "ansible" / "roles"
    workflows_dir = REPO_ROOT / ".github" / "workflows"
    ci_matrix_dir = REPO_ROOT / "ci" / "matrix"
    qops_files = qops_script_sources()

    for doc in collect_docs(inject_bad, inject_phase0):
        text = doc.read_text(encoding="utf-8")
        rel = doc.relative_to(REPO_ROOT)

        errors.extend(check_honesty(doc, text))

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
    if inject_path.is_file() and inject_bad is None and not inject_phase0:
        inject_path.unlink()

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--inject-bad-playbook",
        metavar="NAME",
        help="Append a doc referencing a non-existent playbook (test hook).",
    )
    parser.add_argument(
        "--inject-phase-0-complete",
        action="store_true",
        help="Append a doc claiming Phase 0 passed and Ubuntu 24.04 is Supported.",
    )
    args = parser.parse_args()

    errors = check_docs(
        inject_bad=args.inject_bad_playbook,
        inject_phase0=args.inject_phase_0_complete,
    )
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
