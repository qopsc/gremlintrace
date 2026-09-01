#!/usr/bin/env bash
# Run e2b-seed only when SELECT 1 FROM teams WHERE email=$1 is empty.
set -euo pipefail

EMAIL="${1:?team email required}"
SEED_BIN="${2:?e2b-seed binary required}"
SECRETS_FILE="${3:?secrets file required}"
POSTGRES_CONNECTION_STRING="${4:?postgres connection string required}"
shift 4

if [[ "$#" -lt 1 ]]; then
  echo "psql command required" >&2
  exit 1
fi

exists="$("$@" -v email="${EMAIL}" -tAc "SELECT 1 FROM teams WHERE email = :'email'" | tr -d '[:space:]')"
if [[ "${exists}" == "1" ]]; then
  echo already-seeded
  exit 0
fi

if [[ ! -x "${SEED_BIN}" ]]; then
  echo "e2b-seed binary not executable: ${SEED_BIN}" >&2
  exit 1
fi

seed_out="$(mktemp)"
seed_err="$(mktemp)"
trap 'rm -f "${seed_out}" "${seed_err}"' EXIT
chmod 600 "${seed_out}" "${seed_err}"

set +e
printf '%s\n' "${EMAIL}" | POSTGRES_CONNECTION_STRING="${POSTGRES_CONNECTION_STRING}" \
  "${SEED_BIN}" >"${seed_out}" 2>"${seed_err}"
seed_rc=$?
set -e
if [[ "${seed_rc}" -ne 0 ]]; then
  echo "e2b-seed failed" >&2
  cat "${seed_err}" >&2
  exit "${seed_rc}"
fi

key="$(python3 - "${seed_out}" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
match = re.search(r"Team API Key:\s*(e2b_[0-9a-f]{40})", text)
if not match:
    raise SystemExit("e2b-seed did not print a Team API Key")
sys.stdout.write(match.group(1))
PY
)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${SCRIPT_DIR}/e2b-set-secret.sh" "${SECRETS_FILE}" E2B_API_KEY "${key}" >/dev/null
echo seeded
