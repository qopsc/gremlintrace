#!/usr/bin/env bash
# Assert e2b-assert-dist-pair.sh rejects a tarball whose migrations disagree with BUILD_INFO.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASSERT="${QOPS_CI_ASSERT_DIST_PAIR:-${REPO_ROOT}/ansible/roles/e2b_services/files/e2b-assert-dist-pair.sh}"
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

DIST="${QOPS_CI_DIST_PATH:-/var/cache/qops/ci/e2b-dist.tar.gz}"
if [[ ! -f "${DIST}" ]]; then
  echo "dist tarball missing: ${DIST}" >&2
  exit 1
fi

tar -xzf "${DIST}" -C "${STAGE}"
python3 - "${STAGE}/BUILD_INFO" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
data["expected_migration_timestamp"] = "00000000000000"
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY

if [[ ! -x "${ASSERT}" ]]; then
  echo "assert script missing or not executable: ${ASSERT}" >&2
  exit 1
fi

set +e
"${ASSERT}" --dir "${STAGE}" 2>"${STAGE}/assert.stderr"
rc=$?
set -e

if [[ "${rc}" -eq 0 ]]; then
  echo "expected mismatched API/DB pair to fail" >&2
  exit 1
fi

if [[ "${rc}" -ne 1 ]]; then
  echo "assert script exited ${rc}; expected rejection with exit 1" >&2
  cat "${STAGE}/assert.stderr" >&2 || true
  exit 1
fi

if ! grep -q 'API/migration pair mismatch:' "${STAGE}/assert.stderr"; then
  echo "assert script exited 1 without the expected mismatch message" >&2
  cat "${STAGE}/assert.stderr" >&2 || true
  exit 1
fi

printf 'dist-pair-mismatch: ok (assert script rejected tampered BUILD_INFO)\n'
