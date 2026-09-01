#!/usr/bin/env bash
# Run e2b-seed only when SELECT 1 FROM teams WHERE email=$1 is empty.
# Gate query: accept only empty (seed) or exactly 1 (already-seeded). Fail closed
# on anything else, including connection errors. The seeder deletes that team's
# envs/snapshots on re-run, so a malformed result must never fall through to seed.
#
# The Team API Key is captured to a root-only durable file the moment it is
# parsed. secrets.env is written atomically. Seeding is complete only after
# E2B_API_KEY is verified present. A later already-seeded run recovers the key
# from the durable file if secrets.env lost it.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEEDED_KEY_FILE="${E2B_SEEDED_KEY_FILE:-/etc/qops/e2b/seeded-api-key}"
SEEDED_RAW_FILE="${SEEDED_KEY_FILE}.raw"
KEY_RE='^e2b_[0-9a-f]{40}$'

write_root_only() {
  local dest="$1"
  local content="$2"
  local dest_dir tmp
  dest_dir="$(dirname "${dest}")"
  mkdir -p "${dest_dir}"
  tmp="$(mktemp -p "${dest_dir}" "$(basename "${dest}").XXXXXX")"
  chmod 0600 "${tmp}"
  printf '%s\n' "${content}" >"${tmp}"
  chmod 0600 "${tmp}"
  mv -f "${tmp}" "${dest}"
  chmod 0600 "${dest}"
}

read_existing_key() {
  local file="$1"
  if [[ ! -f "${file}" ]]; then
    return 1
  fi
  python3 - "${file}" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
match = re.search(r"(e2b_[0-9a-f]{40})", text)
if not match:
    raise SystemExit(1)
sys.stdout.write(match.group(1))
PY
}

secrets_key() {
  if [[ ! -f "${SECRETS_FILE}" ]]; then
    return 1
  fi
  local value
  value="$("${SCRIPT_DIR}/e2b-read-secret.sh" "${SECRETS_FILE}" E2B_API_KEY 2>/dev/null || true)"
  if [[ "${value}" =~ ${KEY_RE} ]]; then
    printf '%s' "${value}"
    return 0
  fi
  return 1
}

install_key() {
  local key="$1"
  if [[ ! "${key}" =~ ${KEY_RE} ]]; then
    echo "refusing to persist a malformed E2B API key" >&2
    exit 1
  fi
  write_root_only "${SEEDED_KEY_FILE}" "${key}"
  if [[ ! -f "${SEEDED_KEY_FILE}" ]] || [[ "$(cat "${SEEDED_KEY_FILE}")" != "${key}" ]]; then
    echo "durable API key file is missing after write: ${SEEDED_KEY_FILE}" >&2
    exit 1
  fi
  "${SCRIPT_DIR}/e2b-set-secret.sh" "${SECRETS_FILE}" E2B_API_KEY "${key}" >/dev/null
  local verified
  verified="$("${SCRIPT_DIR}/e2b-read-secret.sh" "${SECRETS_FILE}" E2B_API_KEY)"
  if [[ "${verified}" != "${key}" ]]; then
    echo "E2B_API_KEY missing from ${SECRETS_FILE} after atomic write; key remains in ${SEEDED_KEY_FILE}" >&2
    exit 1
  fi
}

recover_or_fail() {
  local key=""
  if key="$(read_existing_key "${SEEDED_KEY_FILE}")"; then
    :
  elif key="$(secrets_key)"; then
    write_root_only "${SEEDED_KEY_FILE}" "${key}"
  else
    echo "team ${EMAIL} already exists but the plaintext API key is gone (hashed in Postgres, unrecoverable). Refusing to re-seed." >&2
    exit 1
  fi
  if secrets_key >/dev/null && [[ "$(secrets_key)" == "${key}" ]]; then
    echo already-seeded
    exit 0
  fi
  install_key "${key}"
  echo seeded
  exit 0
}

query_err="$(mktemp)"
trap 'rm -f "${query_err}"' EXIT
set +e
exists="$("$@" -v email="${EMAIL}" -tAc "SELECT 1 FROM teams WHERE email = :'email'" 2>"${query_err}")"
query_rc=$?
set -e
if [[ "${query_rc}" -ne 0 ]]; then
  echo "teams gate query failed (connection or SQL error); refusing to seed" >&2
  cat "${query_err}" >&2
  exit "${query_rc}"
fi
exists="$(printf '%s' "${exists}" | tr -d '[:space:]')"

if [[ "${exists}" == "1" ]]; then
  recover_or_fail
fi
if [[ -n "${exists}" ]]; then
  echo "teams gate query returned unexpected result [${exists}]; refusing to seed" >&2
  exit 1
fi

if [[ ! -x "${SEED_BIN}" ]]; then
  echo "e2b-seed binary not executable: ${SEED_BIN}" >&2
  exit 1
fi

seed_out="$(mktemp)"
seed_err="$(mktemp)"
trap 'rm -f "${query_err}" "${seed_out}" "${seed_err}"' EXIT
chmod 600 "${seed_out}" "${seed_err}"

set +e
printf '%s\n' "${EMAIL}" | POSTGRES_CONNECTION_STRING="${POSTGRES_CONNECTION_STRING}" \
  "${SEED_BIN}" >"${seed_out}" 2>"${seed_err}"
seed_rc=$?
set -e
# Persist seeder stdout immediately so a later parse/write failure cannot lose
# the only plaintext copy of the key.
mkdir -p "$(dirname "${SEEDED_RAW_FILE}")"
cp -f "${seed_out}" "${SEEDED_RAW_FILE}"
chmod 0600 "${SEEDED_RAW_FILE}"

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
)" || {
  echo "failed to parse Team API Key from seeder output; raw output kept at ${SEEDED_RAW_FILE}" >&2
  exit 1
}

install_key "${key}"
echo seeded
