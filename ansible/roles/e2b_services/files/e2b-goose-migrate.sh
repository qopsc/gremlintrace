#!/usr/bin/env bash
# Run goose up when pending migrations exist. Prints applied|already-current.
# The connection string is read from GOOSE_DBSTRING rather than argv so it is
# not exposed through /proc/<pid>/cmdline while goose runs.
set -euo pipefail

GOOSE_BIN="${1:?goose binary required}"
DRIVER="${2:?goose driver required}"
MIGRATIONS_DIR="${3:?migrations directory required}"
CONN="${GOOSE_DBSTRING:?GOOSE_DBSTRING environment variable required}"

if [[ ! -x "${GOOSE_BIN}" ]]; then
  echo "goose binary not executable: ${GOOSE_BIN}" >&2
  exit 1
fi
if [[ ! -d "${MIGRATIONS_DIR}" ]]; then
  echo "migrations directory missing: ${MIGRATIONS_DIR}" >&2
  exit 1
fi

status_out="$(GOOSE_DBSTRING="${CONN}" "${GOOSE_BIN}" -dir "${MIGRATIONS_DIR}" "${DRIVER}" status 2>&1 || true)"
if printf '%s\n' "${status_out}" | grep -qi 'pending'; then
  GOOSE_DBSTRING="${CONN}" "${GOOSE_BIN}" -dir "${MIGRATIONS_DIR}" "${DRIVER}" up
  echo applied
  exit 0
fi

# goose status formats vary; if status is unusable, run up and treat "no migrations" as current.
up_out="$(GOOSE_DBSTRING="${CONN}" "${GOOSE_BIN}" -dir "${MIGRATIONS_DIR}" "${DRIVER}" up 2>&1)"
if printf '%s\n' "${up_out}" | grep -Eqi 'OK[[:space:]]+[0-9]{8,}|successfully migrated|applied'; then
  echo applied
  exit 0
fi
echo already-current
