#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${1:?kodus installer directory required}"
shift
if [[ "$#" -lt 1 ]]; then
  echo "at least one health URL is required" >&2
  exit 1
fi

CURL_BIN="${KODUS_CURL_BIN:-curl}"
INSTALL_SH="${KODUS_INSTALL_SH:-${INSTALL_DIR}/scripts/install.sh}"

all_healthy=true
for url in "$@"; do
  set +e
  status="$("${CURL_BIN}" -sS -o /dev/null -w '%{http_code}' --max-time 5 "${url}" 2>/dev/null)"
  curl_rc=$?
  set -e
  if [[ "${curl_rc}" -ne 0 || "${status}" != "200" ]]; then
    all_healthy=false
    break
  fi
done

if [[ "${all_healthy}" == true ]]; then
  echo skipped-healthy
  exit 0
fi

if [[ ! -x "${INSTALL_SH}" && ! -f "${INSTALL_SH}" ]]; then
  echo "missing install.sh: ${INSTALL_SH}" >&2
  exit 1
fi

cd "${INSTALL_DIR}"
bash "${INSTALL_SH}"
echo installed
