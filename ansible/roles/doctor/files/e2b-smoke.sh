#!/usr/bin/env bash
set -euo pipefail

TEMPLATE="${DOCTOR_E2B_TEMPLATE:-kodus-sandbox}"
PROBE="${DOCTOR_ISOLATION_PROBE_SCRIPT:-/usr/local/lib/qops/isolation-probe.sh}"
PUBLIC_IP="${DOCTOR_HOST_PUBLIC_IP:-}"
LAN_IP="${DOCTOR_LAN_IP:-}"
CREATE_CMD="${DOCTOR_SANDBOX_CREATE_CMD:-}"
EXEC_CMD="${DOCTOR_SANDBOX_EXEC_CMD:-}"
KILL_CMD="${DOCTOR_SANDBOX_KILL_CMD:-}"
SECRETS_FILE="${DOCTOR_SECRETS_FILE:-/etc/qops/secrets.env}"
READ_SECRET="${DOCTOR_READ_SECRET_CMD:-/usr/local/lib/qops/e2b-read-secret.sh}"

if [[ -z "${E2B_API_KEY:-}" && -x "${READ_SECRET}" && -f "${SECRETS_FILE}" ]]; then
  E2B_API_KEY="$("${READ_SECRET}" "${SECRETS_FILE}" E2B_API_KEY 2>/dev/null || true)"
  export E2B_API_KEY
fi

json_fail() {
  python3 - "$1" "$2" <<'PY'
import json, sys
print(json.dumps({"ok": False, "echo": "fail", "isolation": {"ok": False}, "killed": False, "error": sys.argv[1], "stage": sys.argv[2]}))
PY
}

if [[ -n "${CREATE_CMD}" ]]; then
  set +e
  sandbox_id="$("${CREATE_CMD}" "${TEMPLATE}")"
  create_rc=$?
  set -e
  if [[ "${create_rc}" -ne 0 || -z "${sandbox_id}" ]]; then
    json_fail "sandbox create failed" "create"
    exit 1
  fi

  set +e
  echo_out="$("${EXEC_CMD}" "${sandbox_id}" echo ok)"
  echo_rc=$?
  set -e
  if [[ "${echo_rc}" -ne 0 || "${echo_out}" != *ok* ]]; then
    "${KILL_CMD}" "${sandbox_id}" >/dev/null 2>&1 || true
    json_fail "echo ok failed" "echo"
    exit 1
  fi

  probe_out=""
  probe_rc=0
  if [[ -n "${EXEC_CMD}" && -x "${PROBE}" ]]; then
    set +e
    probe_out="$("${EXEC_CMD}" "${sandbox_id}" env \
      DOCTOR_HOST_PUBLIC_IP="${PUBLIC_IP}" \
      DOCTOR_LAN_IP="${LAN_IP}" \
      bash "${PROBE}" "${PUBLIC_IP}" "${LAN_IP}")"
    probe_rc=$?
    set -e
  else
    set +e
    probe_out="$("${PROBE}" "${PUBLIC_IP}" "${LAN_IP}")"
    probe_rc=$?
    set -e
  fi

  set +e
  "${KILL_CMD}" "${sandbox_id}" >/dev/null 2>&1
  kill_rc=$?
  set -e

  python3 - "${echo_out}" "${probe_out}" "${probe_rc}" "${kill_rc}" "${sandbox_id}" <<'PY'
import json, sys
echo_out, probe_out, probe_rc, kill_rc, sandbox_id = sys.argv[1:6]
isolation = {}
try:
    isolation = json.loads(probe_out.strip().splitlines()[-1])
except Exception:
    isolation = {"ok": False, "error": "isolation-probe-unparseable", "raw": probe_out[-500:]}
ok = (
    "ok" in echo_out
    and isolation.get("ok") is True
    and probe_rc == "0"
    and kill_rc == "0"
)
print(json.dumps({
    "ok": ok,
    "echo": "ok" if "ok" in echo_out else echo_out.strip()[:80],
    "isolation": isolation,
    "killed": kill_rc == "0",
    "sandbox_id": sandbox_id,
}))
raise SystemExit(0 if ok else 1)
PY
  exit "$?"
fi

NODE_BIN="${DOCTOR_NODE_BIN:-node}"
SMOKE_JS="${DOCTOR_E2B_SMOKE_JS:-/usr/local/lib/qops/e2b-smoke.mjs}"
if [[ -f "${SMOKE_JS}" ]] && command -v "${NODE_BIN}" >/dev/null 2>&1; then
  exec "${NODE_BIN}" "${SMOKE_JS}"
fi

json_fail "no sandbox runner configured" "config"
exit 1
