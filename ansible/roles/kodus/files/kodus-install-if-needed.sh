#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${1:?kodus installer directory required}"
DIGEST_FILE="${2:?digest path required}"
REF="${3:?installer ref required}"

COMPOSE_BASE="${KODUS_COMPOSE_BASE:-${INSTALL_DIR}/docker-compose.yml}"
COMPOSE_OVERRIDE="${KODUS_COMPOSE_OVERRIDE:-${INSTALL_DIR}/docker-compose.override.yml}"
ENV_FILE="${KODUS_ENV_FILE:-${INSTALL_DIR}/.env}"
INSTALL_SH="${KODUS_INSTALL_SH:-${INSTALL_DIR}/scripts/install.sh}"
MERGE_PY="${KODUS_COMPOSE_MERGE_PY:-/usr/local/lib/qops/compose-merge-ports.py}"
WAIT_HEALTH_SH="${KODUS_WAIT_HEALTH_SH:-/usr/local/lib/qops/kodus-wait-health.sh}"
HEALTH_URLS="${KODUS_HEALTH_URLS:?KODUS_HEALTH_URLS (space-separated) required}"
HEALTH_RETRIES="${KODUS_HEALTH_RETRIES:-60}"
HEALTH_DELAY="${KODUS_HEALTH_DELAY:-2}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
COMPOSE_FILES=(-f "${COMPOSE_BASE}")
if [[ -f "${COMPOSE_OVERRIDE}" ]]; then
  COMPOSE_FILES+=(-f "${COMPOSE_OVERRIDE}")
fi

if [[ ! -f "${MERGE_PY}" ]]; then
  echo "missing compose-merge-ports.py: ${MERGE_PY}" >&2
  exit 1
fi

desired="$(python3 "${MERGE_PY}" digest --base "${COMPOSE_BASE}" --override "${COMPOSE_OVERRIDE}" --env-file "${ENV_FILE}" --ref "${REF}")"

containers_exist=false
if command -v "${DOCKER_BIN}" >/dev/null 2>&1; then
  set +e
  running="$("${DOCKER_BIN}" compose "${COMPOSE_FILES[@]}" ps -q 2>/dev/null)"
  docker_rc=$?
  set -e
  if [[ "${docker_rc}" -eq 0 && -n "${running}" ]]; then
    containers_exist=true
  fi
fi

persisted=""
if [[ -f "${DIGEST_FILE}" ]]; then
  persisted="$(tr -d '[:space:]' <"${DIGEST_FILE}")"
fi

if [[ -n "${persisted}" && "${persisted}" == "${desired}" && "${containers_exist}" == true ]]; then
  echo skipped-unchanged
  exit 0
fi

if [[ ! -x "${INSTALL_SH}" && ! -f "${INSTALL_SH}" ]]; then
  echo "missing install.sh: ${INSTALL_SH}" >&2
  exit 1
fi

cd "${INSTALL_DIR}"
bash "${INSTALL_SH}"
# Upstream install.sh has no set -e: a failed health wait or compose up still
# exits 0. Only a healthy stack earns the digest; otherwise the next run
# re-installs instead of skipping a half-up deployment.
for url in ${HEALTH_URLS}; do
  if ! "${WAIT_HEALTH_SH}" "${url}" "${HEALTH_RETRIES}" "${HEALTH_DELAY}"; then
    echo "install.sh finished but Kodus is not healthy at ${url}; digest not written" >&2
    exit 1
  fi
done
umask 077
mkdir -p "$(dirname "${DIGEST_FILE}")"
printf '%s\n' "${desired}" >"${DIGEST_FILE}"
chmod 0600 "${DIGEST_FILE}"
echo installed
