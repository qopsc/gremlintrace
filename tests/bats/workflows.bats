#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  WORKFLOWS_DIR="${REPO_ROOT}/.github/workflows"
}

@test "every workflow uses: is pinned to a 40-character commit SHA" {
  run python3 - "${WORKFLOWS_DIR}" <<'PY'
import re
import sys
from pathlib import Path

workflows_dir = Path(sys.argv[1])
uses_line = re.compile(r"^\s*-\s*uses:\s*(?P<ref>[^\s#]+)")
sha_ref = re.compile(r"^[0-9a-f]{40}$")
float_ref = re.compile(r"^v[0-9]")

errors = []
for path in sorted(workflows_dir.glob("*.yml")):
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        match = uses_line.match(line)
        if not match:
            continue
        ref = match.group("ref")
        if ref.startswith("docker://"):
            continue
        if "@" not in ref:
            errors.append(f"{path}:{lineno}: missing @pin: {ref}")
            continue
        _repo, pin = ref.rsplit("@", 1)
        if float_ref.match(pin):
            errors.append(f"{path}:{lineno}: floating tag {ref!r}")
        elif not sha_ref.fullmatch(pin):
            errors.append(f"{path}:{lineno}: expected 40-char SHA, got {ref!r}")

if errors:
    print("\n".join(errors))
    raise SystemExit(1)
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "workflows do not embed versions.yml pin literals" {
  run python3 - "${REPO_ROOT}/versions.yml" "${WORKFLOWS_DIR}" <<'PY'
import sys
from pathlib import Path

import yaml

versions_path = Path(sys.argv[1])
workflows_dir = Path(sys.argv[2])

with versions_path.open(encoding="utf-8") as fh:
    versions = yaml.safe_load(fh)

workflow_text = "\n".join(
    path.read_text(encoding="utf-8")
    for path in sorted(workflows_dir.glob("*.yml"))
)

errors = []
for key in (
    "e2b_pin",
    "e2b_dist_version",
    "e2b_go_version",
    "firecracker_version",
    "kernel_version",
    "busybox_version",
    "envd_version",
    "e2b_postgres_tag",
    "e2b_redis_tag",
    "e2b_clickhouse_tag",
    "e2b_otel_collector_tag",
    "kodus_installer_ref",
    "kodus_image_tag",
    "traefik_version",
    "goose_version",
    "node_version",
    "e2b_sdk_version",
    "kodus_graph_version",
    "actionlint_version",
    "actionlint_sha256",
    "ansible_core_version",
    "ansible_lint_version",
    "yamllint_version",
    "shellcheck_apt_version",
    "bats_apt_version",
    "node_ci_version",
):
    text = str(versions[key])
    if len(text) < 5:
        continue
    if text in workflow_text:
        errors.append(f"literal for {key!r} ({text!r}) found in workflows")

if errors:
    print("\n".join(errors))
    raise SystemExit(1)
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "repository entry scripts do not import PyYAML" {
  run python3 - "${REPO_ROOT}" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
# The dependency checker itself is a lint-time tool, never invoked by a build or
# mirror job. It runs only under `make check`, where ci/install-lint-tools.sh
# installs PyYAML at a pinned version.
skip = {root / "ci/check_workflow_job_deps.py"}
errors = []
for pattern in ("ci/*.py", "ci/*.sh", "e2b/build/build.sh"):
    for path in sorted(root.glob(pattern)):
        if path in skip:
            continue
        text = path.read_text(encoding="utf-8")
        if re.search(r"(^|\n)import yaml\b", text) or re.search(r"(^|\n)from yaml\b", text):
            errors.append(f"{path}: imports PyYAML")
        if re.search(r"pip\s+install[^\n]*\bpyyaml\b", text, re.IGNORECASE):
            errors.append(f"{path}: pip installs pyyaml")
if errors:
    print("\n".join(errors))
    raise SystemExit(1)
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}
