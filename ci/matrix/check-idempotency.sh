#!/usr/bin/env bash
# Re-run site.yml and assert Ansible reports zero changes; templates must be skipped.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG="${QOPS_CI_IDEMPOTENCY_LOG:-/tmp/qops-site-idempotency.log}"

cd "${REPO_ROOT}"
set +e
./ci/matrix/run-bootstrap.sh --playbook site 2>&1 | tee "${LOG}"
status=$?
set -e

if [[ "${status}" -ne 0 ]]; then
  echo "second site.yml run failed (exit ${status})" >&2
  exit 1
fi

RECAP="$(grep -E '^(localhost|codereviewer)\s+:' "${LOG}" | tail -n1 || true)"
if [[ -z "${RECAP}" ]]; then
  echo "PLAY RECAP line missing from second site.yml log" >&2
  exit 1
fi
if [[ "${RECAP}" =~ changed=([1-9][0-9]*) ]]; then
  echo "second site.yml PLAY RECAP reports changes: ${RECAP}" >&2
  exit 1
fi

if grep -Eiq 'build-templates|e2b-templates.*build|action:\s*build' "${LOG}"; then
  echo "second site.yml triggered a template build" >&2
  exit 1
fi

printf 'idempotency: ok (no changes, no template build)\n'
