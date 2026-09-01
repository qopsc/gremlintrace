#!/usr/bin/env bash
# Print live storage build IDs plus a sentinel. qops-e2b-gc fail-closes
# unless the sentinel is present and this command exits 0.
#
# Live IDs are env_build_assignments.build_id whose env_id is a live template
# (envs.deleted_at IS NULL) or a live snapshot (snapshots.env_id). That set is
# the same as env_builds.id still assigned that way. snapshots.id is a row
# UUID, not a storage key — do not select it.
#
# Header-chain walking (parent build IDs in on-disk headers) is an unverified
# M1 limitation; this query keeps the conservative assigned-build_id set.
set -euo pipefail

PSQL_BIN="${1:?psql helper required}"
shift

SQL=$'SELECT \'__QOPS_E2B_GC_QUERY_OK__\'\nUNION ALL\nSELECT DISTINCT eba.build_id::text\nFROM env_build_assignments eba\nWHERE eba.env_id IN (\n  SELECT id FROM envs WHERE deleted_at IS NULL\n  UNION\n  SELECT env_id FROM snapshots WHERE env_id IS NOT NULL\n);\n'

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
