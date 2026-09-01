#!/usr/bin/env bash
# Print live env_builds/snapshots ids plus a sentinel. qops-e2b-gc fail-closes
# unless the sentinel is present and this command exits 0.
set -euo pipefail

PSQL_BIN="${1:?psql helper required}"
shift

SQL=$'SELECT \'__QOPS_E2B_GC_QUERY_OK__\'\nUNION ALL\nSELECT id::text FROM env_builds WHERE id IS NOT NULL\nUNION ALL\nSELECT id::text FROM snapshots WHERE id IS NOT NULL;\n'

err="$(mktemp)"
trap 'rm -f "${err}"' EXIT
set +e
out="$("${PSQL_BIN}" "$@" -tAc "${SQL}" 2>"${err}")"
rc=$?
set -e
if [[ "${rc}" -ne 0 ]]; then
  echo "qops-e2b-gc query failed" >&2
  cat "${err}" >&2
  exit "${rc}"
fi
printf '%s\n' "${out}"
if ! printf '%s\n' "${out}" | grep -qx '__QOPS_E2B_GC_QUERY_OK__'; then
  echo "qops-e2b-gc query missing sentinel" >&2
  exit 1
fi
