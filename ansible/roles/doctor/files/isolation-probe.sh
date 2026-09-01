#!/usr/bin/env bash
set -euo pipefail

PUBLIC_IP="${1:-${DOCTOR_HOST_PUBLIC_IP:-}}"
LAN_IP="${2:-${DOCTOR_LAN_IP:-}}"
ORCH_PORT="${3:-${DOCTOR_ORCHESTRATOR_PORT:-5008}}"
NPM_URL="${DOCTOR_NPM_URL:-https://registry.npmjs.org}"
CURL_BIN="${ISOLATION_CURL:-${DOCTOR_CURL_CMD:-curl}}"
TIMEOUT="${ISOLATION_TIMEOUT:-3}"

classify_curl() {
  local url="$1" expect="$2"
  local status="000" rc=0 err=""
  if ! command -v "${CURL_BIN}" >/dev/null 2>&1; then
    printf '%s' "inconclusive:curl-missing"
    return
  fi
  local errf
  errf="$(mktemp)"
  set +e
  status="$("${CURL_BIN}" -sS -o /dev/null -w '%{http_code}' --max-time "${TIMEOUT}" -L "${url}" 2>"${errf}")"
  rc=$?
  set -e
  err="$(tr '\n' ' ' <"${errf}" | head -c 200 || true)"
  rm -f "${errf}"
  if [[ "${rc}" -eq 0 && "${status}" =~ ^[1234][0-9][0-9]$ ]]; then
    if [[ "${expect}" == "deny" ]]; then
      printf '%s' "reachable:http-${status}"
    else
      if [[ "${status}" =~ ^[23] ]]; then
        printf '%s' "ok:http-${status}"
      else
        printf '%s' "fail:http-${status}"
      fi
    fi
    return
  fi
  case "${rc}" in
    7|28)
      if [[ "${expect}" == "deny" ]]; then
        printf '%s' "blocked:curl-${rc}"
      else
        printf '%s' "fail:curl-${rc}"
      fi
      ;;
    6)
      printf '%s' "inconclusive:dns"
      ;;
    *)
      if [[ -z "${status}" || "${status}" == "000" ]]; then
        printf '%s' "inconclusive:curl-rc-${rc}:${err}"
      else
        printf '%s' "inconclusive:http-${status}:curl-${rc}"
      fi
      ;;
  esac
}

verdict_of() {
  local raw="$1"
  printf '%s' "${raw%%:*}"
}

if [[ -z "${PUBLIC_IP}" ]]; then
  python3 - <<'PY'
import json
print(json.dumps({
    "ok": False,
    "host_health": "inconclusive",
    "npm": "inconclusive",
    "lan": "inconclusive",
    "host_health_detail": "missing-public-ip",
    "npm_detail": "skipped",
    "lan_detail": "skipped",
}))
PY
  exit 1
fi

if [[ -z "${LAN_IP}" ]]; then
  python3 - <<'PY'
import json
print(json.dumps({
    "ok": False,
    "host_health": "inconclusive",
    "npm": "inconclusive",
    "lan": "inconclusive",
    "host_health_detail": "skipped",
    "npm_detail": "skipped",
    "lan_detail": "missing-lan-ip",
}))
PY
  exit 1
fi

host_raw="$(classify_curl "http://${PUBLIC_IP}:${ORCH_PORT}/health" deny)"
npm_raw="$(classify_curl "${NPM_URL}" allow)"
lan_raw="$(classify_curl "http://${LAN_IP}/" deny)"

host_v="$(verdict_of "${host_raw}")"
npm_v="$(verdict_of "${npm_raw}")"
lan_v="$(verdict_of "${lan_raw}")"

ok=false
if [[ "${host_v}" == "blocked" && "${npm_v}" == "ok" && "${lan_v}" == "blocked" ]]; then
  ok=true
fi

python3 - "${ok}" "${host_v}" "${npm_v}" "${lan_v}" "${host_raw}" "${npm_raw}" "${lan_raw}" "${PUBLIC_IP}" "${LAN_IP}" "${ORCH_PORT}" <<'PY'
import json
import sys

ok, host_v, npm_v, lan_v, host_raw, npm_raw, lan_raw, public_ip, lan_ip, port = sys.argv[1:11]
print(json.dumps({
    "ok": ok == "true",
    "host_health": host_v,
    "npm": npm_v,
    "lan": lan_v,
    "host_health_detail": host_raw,
    "npm_detail": npm_raw,
    "lan_detail": lan_raw,
    "public_ip": public_ip,
    "lan_ip": lan_ip,
    "orchestrator_port": port,
}))
PY

if [[ "${ok}" != true ]]; then
  exit 1
fi
exit 0
