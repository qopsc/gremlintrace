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
UNCHECKED_GATE_LINE_RE = re.compile(r"^- \[ \].*$\n?", re.M)
UBUNTU_SUPPORTED_RE = re.compile(
    r"Ubuntu\s+24\.04.{0,240}Supported|Supported.{0,240}Ubuntu\s+24\.04",
    re.I | re.S,
)
# Single-line claim. Does not match the sign-off header "Phase 0 complete?".
PHASE0_CLAIM_RE = re.compile(
    r"Phase 0(?:[ \t]+\w+){0,6}[ \t]+(?:passed|complete|done)\b(?!\?)",
    re.I,
)


def docs_to_check(
    inject_bad: str | None = None,
    inject_no_checkboxes: bool = False,
    inject_phase0_spike: bool = False,
    inject_ubuntu_supported: bool = False,
) -> list[tuple[Path, str]]:
    """Return (path, text) pairs. Injects overlay in memory; disk is unchanged."""
    overlays: dict[Path, str] = {}
    spike = REPO_ROOT / "docs" / "spike-notes.md"
    ubuntu = REPO_ROOT / "docs" / "distro-notes" / "ubuntu-24.04.md"
    if inject_no_checkboxes:
        overlays[spike] = UNCHECKED_GATE_LINE_RE.sub("", spike.read_text(encoding="utf-8"))
    if inject_phase0_spike:
        overlays[spike] = spike.read_text(encoding="utf-8") + (
            "\n\nPhase 0 complete. Phase 0 passed on nested virt.\n"
        )
    if inject_ubuntu_supported:
        overlays[ubuntu] = ubuntu.read_text(encoding="utf-8") + (
            "\n\nUbuntu 24.04 is Supported as a production distro.\n"
        )

    rows: list[tuple[Path, str]] = []
    for path in DOC_PATHS:
        if path in overlays:
            rows.append((path, overlays[path]))
        elif path.is_file():
            rows.append((path, path.read_text(encoding="utf-8")))
    if inject_bad:
        rows.append(
            (
                REPO_ROOT / "docs" / ".docs-accuracy-inject.md",
                f"# inject\n\nSee ansible/playbooks/{inject_bad}.yml for details.\n",
            )
        )
    return rows


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
    for match in UBUNTU_SUPPORTED_RE.finditer(text):
        if "unverified" in match.group(0).lower():
            continue
        errors.append(
            f"{rel}: docs must not call Ubuntu 24.04 'Supported' "
            "(implemented target, unverified)"
        )
        break
    if PHASE0_CLAIM_RE.search(text):
        errors.append(f"{rel}: docs must not claim Phase 0 passed or complete")
    return errors


def check_docs(
    inject_bad: str | None = None,
    inject_no_checkboxes: bool = False,
    inject_phase0_spike: bool = False,
    inject_ubuntu_supported: bool = False,
) -> list[str]:
    errors: list[str] = []
    playbooks_dir = REPO_ROOT / "ansible" / "playbooks"
    roles_dir = REPO_ROOT / "ansible" / "roles"
    workflows_dir = REPO_ROOT / ".github" / "workflows"
    ci_matrix_dir = REPO_ROOT / "ci" / "matrix"
    qops_files = qops_script_sources()

    for doc, text in docs_to_check(
        inject_bad=inject_bad,
        inject_no_checkboxes=inject_no_checkboxes,
        inject_phase0_spike=inject_phase0_spike,
        inject_ubuntu_supported=inject_ubuntu_supported,
    ):
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
    if inject_path.is_file():
        inject_path.unlink()

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    inj = parser.add_mutually_exclusive_group()
    inj.add_argument(
        "--inject-bad-playbook",
        metavar="NAME",
        help="Append a doc referencing a non-existent playbook (test hook).",
    )
    inj.add_argument(
        "--inject-spike-notes-no-checkboxes",
        action="store_true",
        help="Check spike-notes.md with every `- [ ]` line removed (test hook).",
    )
    inj.add_argument(
        "--inject-spike-notes-phase-0-complete",
        action="store_true",
        help="Check spike-notes.md claiming Phase 0 complete/passed (test hook).",
    )
    inj.add_argument(
        "--inject-ubuntu-supported",
        action="store_true",
        help="Check ubuntu-24.04.md calling the distro Supported (test hook).",
    )
    args = parser.parse_args()

    errors = check_docs(
        inject_bad=args.inject_bad_playbook,
        inject_no_checkboxes=args.inject_spike_notes_no_checkboxes,
        inject_phase0_spike=args.inject_spike_notes_phase_0_complete,
        inject_ubuntu_supported=args.inject_ubuntu_supported,
    )

    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
