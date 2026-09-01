#!/usr/bin/env bash
# Create the extensions schema and pgcrypto when missing.
set -euo pipefail

PSQL_WRAPPER="${1:?psql wrapper required}"
shift

schema="$("${PSQL_WRAPPER}" "$@" -tAc "SELECT 1 FROM pg_namespace WHERE nspname = 'extensions'" | tr -d '[:space:]')"
changed=0
if [[ "${schema}" != "1" ]]; then
  "${PSQL_WRAPPER}" "$@" -c "CREATE SCHEMA extensions"
  changed=1
fi

ext="$("${PSQL_WRAPPER}" "$@" -tAc \
  "SELECT 1 FROM pg_extension e JOIN pg_namespace n ON e.extnamespace = n.oid WHERE e.extname = 'pgcrypto' AND n.nspname = 'extensions'" \
  | tr -d '[:space:]')"
if [[ "${ext}" != "1" ]]; then
  "${PSQL_WRAPPER}" "$@" -c "CREATE EXTENSION pgcrypto SCHEMA extensions"
  changed=1
fi

if [[ "${changed}" -eq 1 ]]; then
  echo created
else
  echo already-present
fi
