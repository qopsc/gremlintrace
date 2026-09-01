#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:?kodus .env required}"
WEBHOOKS_HOST="${2:?dedicated webhooks host required}"
API_HOST="${3:?WEB_HOSTNAME_API host required}"
INSTALL_DIR="${4:?kodus installer directory required}"

VALIDATE_PY="${KODUS_VALIDATE_WEBHOOKS_PY:-/usr/local/lib/qops/validate-kodus-webhooks.py}"
INTERPRET_PY="${KODUS_INTERPRET_DOCTOR_PY:-/usr/local/lib/qops/interpret-kodus-doctor.py}"
DOCTOR_SH="${KODUS_UPSTREAM_DOCTOR_SH:-${INSTALL_DIR}/scripts/doctor.sh}"

python3 "${VALIDATE_PY}" --env "${ENV_FILE}" --webhooks-host "${WEBHOOKS_HOST}"

out="$(mktemp)"
trap 'rm -f "${out}"' EXIT
set +e
(cd "${INSTALL_DIR}" && bash "${DOCTOR_SH}") >"${out}" 2>&1
rc=$?
set -e
python3 "${INTERPRET_PY}" --output-file "${out}" --rc "${rc}" --expected-host "${API_HOST}"
