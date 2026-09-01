#!/usr/bin/env bash
# Run psql against e2b-data postgres via docker compose. Never echo SQL with secrets.
set -euo pipefail

COMPOSE_FILE="${1:?compose file required}"
SECRETS_FILE="${2:?secrets file required}"
PROJECT="${3:?compose project required}"
USER_NAME="${4:?postgres user required}"
DB_NAME="${5:?postgres database required}"
shift 5

docker compose \
  --project-name "${PROJECT}" \
  --env-file "${SECRETS_FILE}" \
  -f "${COMPOSE_FILE}" \
  exec -T postgres \
  psql -U "${USER_NAME}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 "$@"
