#!/usr/bin/env bash
set -euo pipefail

MODE="sandbox"
if [[ "${1:-}" == "--host-proof" ]]; then
  MODE="host-proof"
  shift
elif [[ "${1:-}" == "--sandbox" ]]; then
  MODE="sandbox"
  shift
fi

PUBLIC_IP="${1:-${DOCTOR_HOST_PUBLIC_IP:-}}"
LAN_IP="${2:-${DOCTOR_LAN_IP:-}}"
ORCH_PORT="${3:-${DOCTOR_ORCHESTRATOR_PORT:-5008}}"
NPM_URL="${DOCTOR_NPM_URL:-https://registry.npmjs.org}"
CURL_BIN="${ISOLATION_CURL:-${DOCTOR_CURL_CMD:-curl}}"
TIMEOUT="${ISOLATION_TIMEOUT:-3}"
ORCH_HEALTH_URL="${DOCTOR_ORCH_HEALTH_URL:-http://127.0.0.1:${ORCH_PORT}/health}"
LAN_CONTROL_URL="${DOCTOR_LAN_CONTROL_URL:-http://${LAN_IP}/}"
HOST_LISTENER_HINT="${ISOLATION_HOST_LISTENER:-}"
LAN_LISTENER_HINT="${ISOLATION_LAN_LISTENER:-}"

curl_cmd() {
  local url="$1"
  if ! command -v "${CURL_BIN}" >/dev/null 2>&1; then
    printf '%s' "missing"
    return 127
  fi
  local errf status rc=0
  errf="$(mktemp)"
  set +e
  status="$("${CURL_BIN}" -sS -o /dev/null -w '%{http_code}' --max-time "${TIMEOUT}" --noproxy '*' -L "${url}" 2>"${errf}")"
  rc=$?
  set -e
  rm -f "${errf}"
  printf '%s' "${status:-000}"
  return "${rc}"
}

classify_allow() {
  local status="$1" rc="$2"
  if [[ "${rc}" -eq 127 ]]; then
    printf '%s' "inconclusive:curl-missing"
    return
  fi
  if [[ "${rc}" -eq 0 && "${status}" =~ ^[23][0-9][0-9]$ ]]; then
    printf '%s' "ok:http-${status}"
    return
  fi
  if [[ "${rc}" -eq 6 ]]; then
    printf '%s' "inconclusive:dns"
    return
  fi
  printf '%s' "fail:curl-${rc}:http-${status}"
}

classify_deny() {
  local status="$1" rc="$2" listener="$3"
  if [[ "${rc}" -eq 127 ]]; then
    printf '%s' "inconclusive:curl-missing"
    return
  fi
  if [[ "${rc}" -eq 0 && "${status}" =~ ^[1234][0-9][0-9]$ ]]; then
    printf '%s' "reachable:http-${status}"
    return
  fi
  if [[ "${rc}" -eq 6 ]]; then
    printf '%s' "inconclusive:dns"
    return
  fi
  if [[ "${rc}" -eq 7 || "${rc}" -eq 28 ]]; then
    if [[ "${listener}" != "live" ]]; then
      printf '%s' "inconclusive:unproven-listener:curl-${rc}"
      return
    fi
    printf '%s' "blocked:curl-${rc}"
    return
  fi
  printf '%s' "inconclusive:curl-rc-${rc}:http-${status}"
}

classify_listener() {
  local status="$1" rc="$2"
  if [[ "${rc}" -eq 127 ]]; then
    printf '%s' "inconclusive"
    return
  fi
  if [[ "${rc}" -eq 0 && "${status}" =~ ^[1234][0-9][0-9]$ ]]; then
    printf '%s' "live"
    return
  fi
  if [[ "${rc}" -eq 7 || "${rc}" -eq 28 || "${rc}" -eq 52 ]]; then
    printf '%s' "dead"
    return
  fi
  printf '%s' "inconclusive"
}

ip_kind() {
  python3 - "$1" <<'PY'
import ipaddress
import sys
raw = sys.argv[1]
try:
    addr = ipaddress.ip_address(raw)
except ValueError:
    print("invalid")
    raise SystemExit(0)
if addr.is_loopback or addr.is_link_local or addr.is_multicast or addr.is_unspecified:
    print("invalid")
elif addr.version == 4 and addr in ipaddress.ip_network("100.64.0.0/10"):
    print("private")
elif addr.is_global:
    print("public")
else:
    print("private")
PY
}

emit() {
  python3 - "$@" <<'PY'
import json, sys
keys = [
    "ok", "targets_valid", "host_health", "npm", "lan",
    "host_listener", "lan_listener", "public_ip", "lan_ip",
    "public_class", "lan_class", "host_health_detail", "npm_detail",
    "lan_detail", "mode",
]
vals = sys.argv[1:]
data = dict(zip(keys, vals))
data["ok"] = data["ok"] == "true"
data["targets_valid"] = data["targets_valid"] == "true"
print(json.dumps(data))
PY
}

if [[ -z "${PUBLIC_IP}" || -z "${LAN_IP}" ]]; then
  emit false false inconclusive inconclusive inconclusive \
    inconclusive inconclusive "${PUBLIC_IP}" "${LAN_IP}" \
    invalid invalid \
    missing-targets skipped skipped "${MODE}"
  exit 1
fi

PUBLIC_CLASS="$(ip_kind "${PUBLIC_IP}")"
LAN_CLASS="$(ip_kind "${LAN_IP}")"

targets_valid=false
if [[ "${PUBLIC_CLASS}" == "public" && "${LAN_CLASS}" == "private" && "${PUBLIC_IP}" != "${LAN_IP}" ]]; then
  targets_valid=true
fi

if [[ "${targets_valid}" != true ]]; then
  emit false false inconclusive inconclusive inconclusive \
    inconclusive inconclusive "${PUBLIC_IP}" "${LAN_IP}" \
    "${PUBLIC_CLASS}" "${LAN_CLASS}" \
    invalid-targets skipped skipped "${MODE}"
  exit 1
fi

host_listener="${HOST_LISTENER_HINT}"
lan_listener="${LAN_LISTENER_HINT}"

if [[ "${MODE}" == "host-proof" ]]; then
  rc=0
  status="$(curl_cmd "${ORCH_HEALTH_URL}")" || rc=$?
  if [[ "${status}" == "missing" ]]; then rc=127; fi
  host_listener="$(classify_listener "${status}" "${rc}")"
  rc=0
  status="$(curl_cmd "${LAN_CONTROL_URL}")" || rc=$?
  if [[ "${status}" == "missing" ]]; then rc=127; fi
  lan_listener="$(classify_listener "${status}" "${rc}")"
  ok=false
  if [[ "${host_listener}" == "live" && "${lan_listener}" == "live" ]]; then
    ok=true
  fi
  emit "${ok}" true unproven unproven unproven \
    "${host_listener}" "${lan_listener}" "${PUBLIC_IP}" "${LAN_IP}" \
    "${PUBLIC_CLASS}" "${LAN_CLASS}" \
    host-proof skipped skipped "${MODE}"
  if [[ "${ok}" != true ]]; then
    exit 1
  fi
  exit 0
fi

if [[ "${host_listener}" != "live" ]]; then
  host_listener="${host_listener:-unproven}"
fi
if [[ "${lan_listener}" != "live" ]]; then
  lan_listener="${lan_listener:-unproven}"
fi

host_rc=0
status="$(curl_cmd "http://${PUBLIC_IP}:${ORCH_PORT}/health")" || host_rc=$?
if [[ "${status}" == "missing" ]]; then host_rc=127; fi
host_raw="$(classify_deny "${status}" "${host_rc}" "${host_listener}")"

npm_rc=0
status="$(curl_cmd "${NPM_URL}")" || npm_rc=$?
if [[ "${status}" == "missing" ]]; then npm_rc=127; fi
npm_raw="$(classify_allow "${status}" "${npm_rc}")"

lan_rc=0
status="$(curl_cmd "http://${LAN_IP}/")" || lan_rc=$?
if [[ "${status}" == "missing" ]]; then lan_rc=127; fi
lan_raw="$(classify_deny "${status}" "${lan_rc}" "${lan_listener}")"

host_v="${host_raw%%:*}"
npm_v="${npm_raw%%:*}"
lan_v="${lan_raw%%:*}"

ok=false
if [[ "${host_v}" == "blocked" && "${npm_v}" == "ok" && "${lan_v}" == "blocked" && "${host_listener}" == "live" && "${lan_listener}" == "live" ]]; then
  ok=true
fi

emit "${ok}" true "${host_v}" "${npm_v}" "${lan_v}" \
  "${host_listener}" "${lan_listener}" "${PUBLIC_IP}" "${LAN_IP}" \
  "${PUBLIC_CLASS}" "${LAN_CLASS}" \
  "${host_raw}" "${npm_raw}" "${lan_raw}" "${MODE}"

if [[ "${ok}" != true ]]; then
  exit 1
fi
exit 0
