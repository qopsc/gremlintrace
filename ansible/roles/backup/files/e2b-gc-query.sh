#!/usr/bin/env bash
# Print live storage build IDs plus a sentinel. qops-e2b-gc fail-closes
# unless the sentinel is present and this command exits 0.
#
# Live IDs include every build row belonging to a non-deleted environment,
# assignments reachable from live templates or snapshots, and the build_id
# recorded by snapshot_templates. snapshots.id is a row UUID, not a storage
# key — do not select it.
#
# Header-chain walking (parent build IDs in on-disk headers) is an unverified
# M1 limitation; this query keeps every database-level live reference.
set -euo pipefail

PSQL_BIN="${1:?psql helper required}"
shift

SQL=$'SELECT \'__QOPS_E2B_GC_QUERY_OK__\'\nUNION\nSELECT DISTINCT eb.id::text\nFROM env_builds eb\nJOIN envs e ON e.id = eb.env_id\nWHERE e.deleted_at IS NULL\nUNION\nSELECT DISTINCT eba.build_id::text\nFROM env_build_assignments eba\nWHERE eba.env_id IN (\n  SELECT id FROM envs WHERE deleted_at IS NULL\n  UNION\n  SELECT env_id FROM snapshots WHERE env_id IS NOT NULL\n  UNION\n  SELECT base_env_id FROM snapshots WHERE base_env_id IS NOT NULL\n)\nUNION\nSELECT DISTINCT st.build_id::text\nFROM snapshot_templates st\nWHERE st.build_id IS NOT NULL;\n'

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
