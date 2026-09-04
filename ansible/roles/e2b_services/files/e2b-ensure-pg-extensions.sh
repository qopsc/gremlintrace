#!/usr/bin/env bash
# Create the extensions schema when missing.
set -euo pipefail

PSQL_WRAPPER="${1:?psql wrapper required}"
shift

schema="$("${PSQL_WRAPPER}" "$@" -tAc "SELECT 1 FROM pg_namespace WHERE nspname = 'extensions'" | tr -d '[:space:]')"
if [[ "${schema}" != "1" ]]; then
  "${PSQL_WRAPPER}" "$@" -c "CREATE SCHEMA extensions"
  echo created
else
  echo already-present
fi
