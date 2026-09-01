#!/usr/bin/env bash
# Idempotently insert the concurrency addon and raise tiers.max_length_hours if needed.
set -euo pipefail

EMAIL="${1:?team email required}"
ADDON_NAME="${2:?addon name required}"
EXTRA_SANDBOXES="${3:?extra concurrent sandboxes required}"
EXTRA_BUILDS="${4:?extra concurrent template builds required}"
MAX_HOURS="${5:?max sandbox hours required}"
shift 5

if [[ "$#" -lt 1 ]]; then
  echo "psql command required" >&2
  exit 1
fi
if ! [[ "${EXTRA_SANDBOXES}" =~ ^[0-9]+$ && "${EXTRA_BUILDS}" =~ ^[0-9]+$ && "${MAX_HOURS}" =~ ^[0-9]+$ ]]; then
  echo "extra sandboxes, extra builds, and max hours must be integers" >&2
  exit 1
fi

changed=0
psql_vars=(-v email="${EMAIL}" -v addon_name="${ADDON_NAME}")

addon_state="$("$@" "${psql_vars[@]}" -tA -c "\
SELECT COALESCE((
  SELECT extra_concurrent_sandboxes::text || ':' || extra_concurrent_template_builds::text
  FROM addons a
  JOIN teams t ON t.id = a.team_id
  WHERE t.email = :'email' AND a.name = :'addon_name'
  LIMIT 1
), '')")"
addon_state="$(printf '%s' "${addon_state}" | tr -d '[:space:]')"

wanted="${EXTRA_SANDBOXES}:${EXTRA_BUILDS}"
if [[ -z "${addon_state}" ]]; then
  "$@" "${psql_vars[@]}" -c "\
INSERT INTO addons (team_id, name, extra_concurrent_sandboxes, extra_concurrent_template_builds, added_by)
SELECT t.id, :'addon_name', ${EXTRA_SANDBOXES}::bigint, ${EXTRA_BUILDS}::bigint, u.id
FROM teams t
JOIN auth.users u ON u.email = t.email
WHERE t.email = :'email'"
  changed=1
elif [[ "${addon_state}" != "${wanted}" ]]; then
  "$@" "${psql_vars[@]}" -c "\
UPDATE addons a
SET extra_concurrent_sandboxes = ${EXTRA_SANDBOXES}::bigint,
    extra_concurrent_template_builds = ${EXTRA_BUILDS}::bigint
FROM teams t
WHERE a.team_id = t.id AND t.email = :'email' AND a.name = :'addon_name'"
  changed=1
fi

updated="$("$@" -tAc "\
UPDATE tiers
SET max_length_hours = ${MAX_HOURS}::bigint
WHERE id = 'base_v1' AND max_length_hours < ${MAX_HOURS}::bigint
RETURNING 1" | tr -d '[:space:]')"
if [[ "${updated}" == "1" ]]; then
  changed=1
fi

if [[ "${changed}" -eq 1 ]]; then
  echo changed
else
  echo unchanged
fi
