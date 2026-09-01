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
print(json.dumps({
    "ok": False,
    "echo": "fail",
    "isolation": {
        "ok": False,
        "targets_valid": False,
        "host_health": "inconclusive",
        "npm": "inconclusive",
        "lan": "inconclusive",
        "host_listener": "inconclusive",
        "lan_listener": "inconclusive",
        "error": sys.argv[1],
    },
    "killed": False,
    "error": sys.argv[1],
    "stage": sys.argv[2],
}))
PY
}

merge_isolation() {
  python3 - "$1" "$2" <<'PY'
import json, sys
host = json.loads(sys.argv[1].strip().splitlines()[-1])
sandbox = json.loads(sys.argv[2].strip().splitlines()[-1])
required = (
    "ok", "targets_valid", "host_health", "npm", "lan",
    "host_listener", "lan_listener", "public_ip", "lan_ip",
    "public_class", "lan_class",
)
merged = dict(host)
merged.update({k: sandbox.get(k, merged.get(k)) for k in (
    "host_health", "npm", "lan", "host_health_detail", "npm_detail", "lan_detail", "mode",
)})
merged["host_listener"] = host.get("host_listener")
merged["lan_listener"] = host.get("lan_listener")
merged["targets_valid"] = host.get("targets_valid") is True and sandbox.get("targets_valid") is True
ok = (
    merged.get("targets_valid") is True
    and merged.get("host_listener") == "live"
    and merged.get("lan_listener") == "live"
    and sandbox.get("host_health") == "blocked"
    and sandbox.get("npm") == "ok"
    and sandbox.get("lan") == "blocked"
)
merged["ok"] = ok
missing = [k for k in required if k not in merged]
if missing:
    merged["ok"] = False
    merged["error"] = "missing-fields:" + ",".join(missing)
print(json.dumps(merged))
raise SystemExit(0 if ok else 1)
PY
}

host_proof() {
  if [[ ! -x "${PROBE}" && ! -f "${PROBE}" ]]; then
    json_fail "isolation probe missing" "host-proof"
    exit 1
  fi
  set +e
  HOST_PROOF_JSON="$(bash "${PROBE}" --host-proof "${PUBLIC_IP}" "${LAN_IP}" 2>&1)"
  host_rc=$?
  set -e
  HOST_PROOF_JSON="$(printf '%s\n' "${HOST_PROOF_JSON}" | tail -n1)"
  if [[ "${host_rc}" -ne 0 ]]; then
    python3 - "${HOST_PROOF_JSON}" <<'PY'
import json, sys
raw = sys.argv[1]
try:
    iso = json.loads(raw)
except Exception:
    iso = {"ok": False, "error": "host-proof-unparseable", "raw": raw[-400:]}
iso["ok"] = False
print(json.dumps({
    "ok": False,
    "echo": "fail",
    "isolation": iso,
    "killed": False,
    "stage": "host-proof",
}))
PY
    exit 1
  fi
  export ISOLATION_HOST_LISTENER
  export ISOLATION_LAN_LISTENER
  ISOLATION_HOST_LISTENER="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("host_listener",""))' "${HOST_PROOF_JSON}")"
  ISOLATION_LAN_LISTENER="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("lan_listener",""))' "${HOST_PROOF_JSON}")"
}

if [[ -n "${CREATE_CMD}" ]]; then
  host_proof

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

  set +e
  probe_out="$("${EXEC_CMD}" "${sandbox_id}" env \
    DOCTOR_HOST_PUBLIC_IP="${PUBLIC_IP}" \
    DOCTOR_LAN_IP="${LAN_IP}" \
    ISOLATION_HOST_LISTENER="${ISOLATION_HOST_LISTENER}" \
    ISOLATION_LAN_LISTENER="${ISOLATION_LAN_LISTENER}" \
    bash "${PROBE}" --sandbox "${PUBLIC_IP}" "${LAN_IP}")"
  probe_rc=$?
  set -e
  if [[ "${probe_rc}" -ne 0 && -z "${probe_out}" ]]; then
    probe_out='{"ok":false,"targets_valid":false,"host_health":"inconclusive","npm":"inconclusive","lan":"inconclusive"}'
  fi

  set +e
  "${KILL_CMD}" "${sandbox_id}" >/dev/null 2>&1
  kill_rc=$?
  set -e

  probe_out="$(printf '%s\n' "${probe_out}" | tail -n1)"
  set +e
  iso_json="$(merge_isolation "${HOST_PROOF_JSON}" "${probe_out}")"
  iso_rc=$?
  set -e

  python3 - "${echo_out}" "${iso_json}" "${iso_rc}" "${kill_rc}" "${sandbox_id}" <<'PY'
import json, sys
echo_out, iso_json, iso_rc, kill_rc, sandbox_id = sys.argv[1:6]
try:
    isolation = json.loads(iso_json)
except Exception:
    isolation = {"ok": False, "error": "isolation-merge-unparseable", "raw": iso_json[-500:]}
ok = (
    "ok" in echo_out
    and isolation.get("ok") is True
    and isolation.get("targets_valid") is True
    and isolation.get("host_health") == "blocked"
    and isolation.get("npm") == "ok"
    and isolation.get("lan") == "blocked"
    and isolation.get("host_listener") == "live"
    and isolation.get("lan_listener") == "live"
    and iso_rc == "0"
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
  host_proof
  export ISOLATION_HOST_LISTENER ISOLATION_LAN_LISTENER HOST_PROOF_JSON
  exec "${NODE_BIN}" "${SMOKE_JS}"
fi

json_fail "no sandbox runner configured" "config"
exit 1
