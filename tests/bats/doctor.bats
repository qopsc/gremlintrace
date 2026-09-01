#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  DOCTOR="${REPO_ROOT}/ansible/roles/doctor/files/qops-doctor"
  PROBE="${REPO_ROOT}/ansible/roles/doctor/files/isolation-probe.sh"
  SMOKE="${REPO_ROOT}/ansible/roles/doctor/files/e2b-smoke.sh"
  ROOT="${BATS_TMPDIR}/doctor-world"
  prepare_world
}

prepare_world() {
  rm -rf "${ROOT}"
  mkdir -p "${ROOT}/bin" "${ROOT}/modules/6.8.0/kernel" "${ROOT}/modules/6.11.0/kernel" \
    "${ROOT}/sys/block/nbd0" "${ROOT}/store" "${ROOT}/disk/e2b" "${ROOT}/disk/orchestrator"
  echo 0 >"${ROOT}/sys/block/nbd0/size"
  touch "${ROOT}/modules/6.11.0/kernel/nbd.ko"
  cat >"${ROOT}/meminfo" <<'EOF'
MemTotal:       32768000 kB
HugePages_Total:    1000
HugePages_Free:      400
Hugepagesize:       2048 kB
EOF
  cat >"${ROOT}/bin/preflight" <<EOF
#!/usr/bin/env bash
cat >"\${PREFLIGHT_REPORT_PATH}" <<'JSON'
{"version": 1, "timestamp": "t", "passed": true, "checks": [], "failures": []}
JSON
exit 0
EOF
  cat >"${ROOT}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ "${1}" == "is-active" ]]; then
  unit="${3:-${2}}"
  if [[ "${unit}" == "${DOCTOR_FAIL_UNIT:-}" ]]; then
    exit 1
  fi
  exit 0
fi
exit 0
EOF
  cat >"${ROOT}/bin/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "${DOCTOR_CURL_FAIL_URL:-}" != "" ]]; then
  for arg in "$@"; do
    if [[ "${arg}" == "${DOCTOR_CURL_FAIL_URL}" ]]; then
      echo -n 000
      exit 1
    fi
  done
fi
echo -n 200
exit 0
EOF
  cat >"${ROOT}/bin/df" <<'EOF'
#!/usr/bin/env bash
path="${2:-${1}}"
pct="${DOCTOR_DF_PERCENT:-10}"
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/x 100 10 90 %s%% %s\n' "${pct}" "${path}"
EOF
  cat >"${ROOT}/bin/du" <<'EOF'
#!/usr/bin/env bash
echo "4096 ${2:-${1}}"
EOF
  cat >"${ROOT}/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "${DOCTOR_DOCKER_FAIL:-}" == "1" ]]; then
  exit 1
fi
if [[ "$*" == *list_queues* ]]; then
  echo "workflow.jobs 0"
  exit 0
fi
if [[ "$1" == "logs" ]]; then
  printf '%s\n' "${DOCTOR_WORKER_LOG:-ready}"
  exit 0
fi
exit 0
EOF
  cat >"${ROOT}/bin/smoke" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${DOCTOR_SMOKE_JSON:-}" ]]; then
  printf '%s\n' "${DOCTOR_SMOKE_JSON}"
  python3 - "${DOCTOR_SMOKE_JSON}" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
raise SystemExit(0 if d.get("ok") and d.get("echo") == "ok" and d.get("killed") else 1)
PY
  exit $?
fi
echo '{"ok": true, "echo": "ok", "killed": true, "isolation": {"ok": true, "targets_valid": true, "host_health": "blocked", "npm": "ok", "lan": "blocked", "host_listener": "live", "lan_listener": "live", "public_ip": "8.8.8.8", "lan_ip": "10.0.0.5", "public_class": "public", "lan_class": "private"}}'
exit 0
EOF
  chmod +x "${ROOT}/bin/"*
}

pass_env() {
  export PATH="${ROOT}/bin:${PATH}"
  export DOCTOR_REPORT_PATH="${ROOT}/doctor.json"
  export DOCTOR_PREFLIGHT_SCRIPT="${ROOT}/bin/preflight"
  export DOCTOR_PREFLIGHT_REPORT="${ROOT}/preflight.json"
  export PREFLIGHT_REPORT_PATH="${ROOT}/preflight.json"
  export DOCTOR_SYSTEMCTL_CMD="${ROOT}/bin/systemctl"
  export DOCTOR_DOCKER_CMD="${ROOT}/bin/docker"
  export DOCTOR_CURL_CMD="${ROOT}/bin/curl"
  export DOCTOR_MEMINFO="${ROOT}/meminfo"
  export DOCTOR_MODULES_DIR="${ROOT}/modules"
  export DOCTOR_NBD_SYSFS="${ROOT}/sys/block"
  export DOCTOR_DF_CMD="${ROOT}/bin/df"
  export DOCTOR_DU_CMD="${ROOT}/bin/du"
  export DOCTOR_TEMPLATE_STORE="${ROOT}/store"
  export DOCTOR_DISK_PATHS="${ROOT}/disk/e2b ${ROOT}/disk/orchestrator"
  export DOCTOR_E2B_SMOKE_CMD="${ROOT}/bin/smoke"
  export DOCTOR_WORKER_LOGS_CMD="${ROOT}/bin/docker logs kodus-worker-prod"
  export DOCTOR_RABBITMQ_QUEUES_CMD="${ROOT}/bin/docker exec rabbitmq-prod rabbitmqctl list_queues"
  export DOCTOR_WEBHOOK_URL="https://kodus-webhooks.example.com/health"
  export DOCTOR_KODUS_WEB_HEALTH="http://127.0.0.1:3000/health"
  export DOCTOR_KODUS_API_HEALTH="http://127.0.0.1:3001/health"
  export DOCTOR_KODUS_WEBHOOKS_HEALTH="http://127.0.0.1:3332/health"
}

doctor_ids() {
  python3 - "$1" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
print(" ".join(c["id"] for c in report["checks"] if not c["passed"] and not c.get("skipped")))
PY
}

@test "qops-doctor passes when every stubbed check succeeds" {
  pass_env
  run bash "${DOCTOR}"
  echo "$output"
  [ "$status" -eq 0 ]
  python3 - "${ROOT}/doctor.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["passed"] is True, r
assert r["failures"] == []
ids = {c["id"] for c in r["checks"]}
for expected in (
    "preflight", "unit_e2b_orchestrator", "unit_e2b_api", "unit_e2b_client_proxy",
    "unit_traefik", "hugepages", "nbd_in_use", "nbd_ko_newest_kernel", "disk_usage",
    "template_store", "kodus_web_health", "kodus_api_health", "kodus_webhooks_health",
    "rabbitmq_queues", "e2b_smoke", "isolation_probe", "webhook_reachability",
    "worker_fallback",
):
    assert expected in ids, expected
webhook = next(c for c in r["checks"] if c["id"] == "webhook_reachability")
assert webhook.get("skipped") is True, webhook
assert webhook["passed"] is False
print("ok")
PY
}

@test "each check can fail individually and is named in the summary" {
  pass_env
  declare -A flips
  flips[preflight]=preflight
  flips[unit_e2b_orchestrator]=unit
  flips[hugepages]=hugepages
  flips[nbd_in_use]=nbd_sysfs
  flips[nbd_ko_newest_kernel]=nbd_ko
  flips[disk_usage]=disk
  flips[template_store]=store
  flips[kodus_web_health]=web
  flips[rabbitmq_queues]=rabbit
  flips[e2b_smoke]=smoke
  flips[isolation_probe]=isolation
  flips[webhook_reachability]=webhook
  flips[worker_fallback]=fallback

  fail_one() {
    local id="$1" mode="$2"
    unset DOCTOR_FAIL_UNIT DOCTOR_CURL_FAIL_URL DOCTOR_DF_PERCENT DOCTOR_DOCKER_FAIL \
      DOCTOR_SMOKE_JSON DOCTOR_WORKER_LOG DOCTOR_NBD_SYSFS DOCTOR_TEMPLATE_STORE \
      DOCTOR_WEBHOOK_URL DOCTOR_WEBHOOK_EXTERNAL_PROBE_CMD
    prepare_world
    pass_env
    case "${mode}" in
      preflight)
        cat >"${ROOT}/bin/preflight" <<'EOF'
#!/usr/bin/env bash
cat >"${PREFLIGHT_REPORT_PATH}" <<'JSON'
{"version": 1, "timestamp": "t", "passed": false, "checks": [], "failures": ["no kvm"]}
JSON
exit 1
EOF
        chmod +x "${ROOT}/bin/preflight"
        ;;
      unit) export DOCTOR_FAIL_UNIT=e2b-orchestrator ;;
      hugepages)
        cat >"${ROOT}/meminfo" <<'EOF'
HugePages_Total:       0
HugePages_Free:        0
Hugepagesize:       2048 kB
EOF
        ;;
      nbd_sysfs) export DOCTOR_NBD_SYSFS="${ROOT}/missing-sys" ;;
      nbd_ko) rm -f "${ROOT}/modules/6.11.0/kernel/nbd.ko" ;;
      disk) export DOCTOR_DF_PERCENT=99 ;;
      store) export DOCTOR_TEMPLATE_STORE="${ROOT}/missing-store" ;;
      web) export DOCTOR_CURL_FAIL_URL="http://127.0.0.1:3000/health" ;;
      rabbit) export DOCTOR_DOCKER_FAIL=1 ;;
      smoke)
        export DOCTOR_SMOKE_JSON='{"ok": false, "echo": "fail", "killed": false, "isolation": {"ok": true, "targets_valid": true, "host_health": "blocked", "npm": "ok", "lan": "blocked", "host_listener": "live", "lan_listener": "live"}}'
        ;;
      isolation)
        export DOCTOR_SMOKE_JSON='{"ok": true, "echo": "ok", "killed": true, "isolation": {"ok": false, "targets_valid": true, "host_health": "inconclusive", "npm": "ok", "lan": "blocked", "host_listener": "live", "lan_listener": "live"}}'
        ;;
      webhook)
        export DOCTOR_WEBHOOK_EXTERNAL_PROBE_CMD="false"
        ;;
      fallback) export DOCTOR_WORKER_LOG="usedTemplate=false falling back to default" ;;
    esac
    run bash "${DOCTOR}"
    [ "$status" -eq 1 ]
    failed="$(doctor_ids "${ROOT}/doctor.json")"
    [[ "${failed}" == *"${id}"* ]]
    python3 - "${ROOT}/doctor.json" "${id}" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["passed"] is False
assert any(c["id"] == sys.argv[2] and not c["passed"] and not c.get("skipped") for c in r["checks"])
assert r["failures"], r
print("failures", len(r["failures"]))
PY
  }

  fail_one preflight preflight
  fail_one unit_e2b_orchestrator unit
  fail_one hugepages hugepages
  fail_one nbd_in_use nbd_sysfs
  fail_one nbd_ko_newest_kernel nbd_ko
  fail_one disk_usage disk
  fail_one template_store store
  fail_one kodus_web_health web
  fail_one rabbitmq_queues rabbit
  fail_one e2b_smoke smoke
  fail_one isolation_probe isolation
  fail_one webhook_reachability webhook
  fail_one worker_fallback fallback

  prepare_world
  pass_env
  export DOCTOR_FAIL_UNIT=e2b-api
  run bash "${DOCTOR}"
  [ "$status" -eq 1 ]
  [[ "$(doctor_ids "${ROOT}/doctor.json")" == *unit_e2b_api* ]]

  prepare_world
  pass_env
  export DOCTOR_FAIL_UNIT=e2b-client-proxy
  run bash "${DOCTOR}"
  [ "$status" -eq 1 ]
  [[ "$(doctor_ids "${ROOT}/doctor.json")" == *unit_e2b_client_proxy* ]]

  prepare_world
  pass_env
  export DOCTOR_FAIL_UNIT=traefik
  run bash "${DOCTOR}"
  [ "$status" -eq 1 ]
  [[ "$(doctor_ids "${ROOT}/doctor.json")" == *unit_traefik* ]]

  prepare_world
  pass_env
  export DOCTOR_CURL_FAIL_URL="http://127.0.0.1:3001/health"
  run bash "${DOCTOR}"
  [ "$status" -eq 1 ]
  [[ "$(doctor_ids "${ROOT}/doctor.json")" == *kodus_api_health* ]]

  prepare_world
  pass_env
  export DOCTOR_CURL_FAIL_URL="http://127.0.0.1:3332/health"
  run bash "${DOCTOR}"
  [ "$status" -eq 1 ]
  [[ "$(doctor_ids "${ROOT}/doctor.json")" == *kodus_webhooks_health* ]]
}

@test "all failures are reported together with a non-zero exit" {
  pass_env
  cat >"${ROOT}/bin/preflight" <<'EOF'
#!/usr/bin/env bash
cat >"${PREFLIGHT_REPORT_PATH}" <<'JSON'
{"version": 1, "timestamp": "t", "passed": false, "checks": [], "failures": ["arch", "kvm"]}
JSON
exit 1
EOF
  chmod +x "${ROOT}/bin/preflight"
  export DOCTOR_FAIL_UNIT=traefik
  cat >"${ROOT}/meminfo" <<'EOF'
HugePages_Total: 0
HugePages_Free: 0
Hugepagesize: 2048 kB
EOF
  rm -f "${ROOT}/modules/6.11.0/kernel/nbd.ko"
  export DOCTOR_DF_PERCENT=99
  export DOCTOR_TEMPLATE_STORE="${ROOT}/no-store"
  export DOCTOR_NBD_SYSFS="${ROOT}/no-sys"
  export DOCTOR_CURL_FAIL_URL="http://127.0.0.1:3000/health"
  export DOCTOR_DOCKER_FAIL=1
  export DOCTOR_WEBHOOK_URL=""
  export DOCTOR_WEBHOOK_EXTERNAL_PROBE_CMD="false"
  export DOCTOR_WORKER_LOG="falling back to default"
  export DOCTOR_SMOKE_JSON='{"ok": false, "echo": "fail", "killed": false, "isolation": {"ok": false, "targets_valid": true, "host_health": "reachable", "npm": "fail", "lan": "inconclusive", "host_listener": "live", "lan_listener": "dead"}}'
  run bash "${DOCTOR}"
  [ "$status" -eq 1 ]
  python3 - "${ROOT}/doctor.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["passed"] is False
failed = {c["id"] for c in r["checks"] if not c["passed"]}
for expected in (
    "preflight", "unit_traefik", "hugepages", "nbd_in_use", "nbd_ko_newest_kernel",
    "disk_usage", "template_store", "kodus_web_health", "rabbitmq_queues",
    "e2b_smoke", "isolation_probe", "webhook_reachability", "worker_fallback",
):
    assert expected in failed, (expected, failed)
assert len(r["failures"]) >= 8, r["failures"]
print(len(r["failures"]))
PY
  [[ "$output" == *"FAIL:"* ]]
}

@test "nbd.ko check uses the newest installed kernel not the running one" {
  pass_env
  rm -f "${ROOT}/modules/6.11.0/kernel/nbd.ko"
  touch "${ROOT}/modules/6.8.0/kernel/nbd.ko"
  run bash "${DOCTOR}"
  [ "$status" -eq 1 ]
  python3 - "${ROOT}/doctor.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
nbd = next(c for c in r["checks"] if c["id"] == "nbd_ko_newest_kernel")
assert nbd["passed"] is False, nbd
assert "6.11.0" in nbd["message"], nbd
print("ok")
PY
}

@test "worker logs containing falling back to default fail doctor" {
  pass_env
  export DOCTOR_WORKER_LOG="sandbox create usedTemplate=false falling back to default"
  run bash "${DOCTOR}"
  [ "$status" -eq 1 ]
  python3 - "${ROOT}/doctor.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
chk = next(c for c in r["checks"] if c["id"] == "worker_fallback")
assert chk["passed"] is False, chk
assert "falling back to default" in chk["message"]
print("ok")
PY
}

@test "isolation probe treats blocked as pass and inconclusive as fail" {
  cat >"${ROOT}/bin/curl-probe" <<'EOF'
#!/usr/bin/env bash
url=""
for arg in "$@"; do
  case "${arg}" in
    http*|https*) url="${arg}" ;;
  esac
done
case "${url}" in
  *127.0.0.1:5008*) echo -n 200; exit 0 ;;
  *8.8.8.8:5008*) exit 28 ;;
  *registry.npmjs.org*) echo -n 200; exit 0 ;;
  *10.0.0.5*) exit 7 ;;
  *) echo -n 000; exit 1 ;;
esac
EOF
  chmod +x "${ROOT}/bin/curl-probe"
  run env ISOLATION_CURL="${ROOT}/bin/curl-probe" \
    DOCTOR_ORCH_HEALTH_URL="http://127.0.0.1:5008/health" \
    DOCTOR_LAN_CONTROL_URL="http://127.0.0.1:5008/health" \
    bash "${PROBE}" --host-proof 8.8.8.8 10.0.0.5
  [ "$status" -eq 0 ]
  python3 -c '
import json, sys
d = json.loads(sys.argv[1].strip().splitlines()[-1])
assert d["ok"] is True
assert d["host_listener"] == "live"
assert d["lan_listener"] == "live"
print("ok")
' "$output"

  run env ISOLATION_CURL="${ROOT}/bin/curl-probe" ISOLATION_HOST_LISTENER=live ISOLATION_LAN_LISTENER=live \
    bash "${PROBE}" --sandbox 8.8.8.8 10.0.0.5
  [ "$status" -eq 0 ]
  python3 -c '
import json, sys
d = json.loads(sys.argv[1].strip().splitlines()[-1])
assert d["ok"] is True
assert d["targets_valid"] is True
assert d["host_health"] == "blocked"
assert d["npm"] == "ok"
assert d["lan"] == "blocked"
print("ok")
' "$output"

  cat >"${ROOT}/bin/curl-probe" <<'EOF'
#!/usr/bin/env bash
url=""
for arg in "$@"; do
  case "${arg}" in
    http*|https*) url="${arg}" ;;
  esac
done
case "${url}" in
  *8.8.8.8:5008*) echo -n 200; exit 0 ;;
  *registry.npmjs.org*) echo -n 200; exit 0 ;;
  *10.0.0.5*) exit 7 ;;
  *) exit 1 ;;
esac
EOF
  run env ISOLATION_CURL="${ROOT}/bin/curl-probe" ISOLATION_HOST_LISTENER=live ISOLATION_LAN_LISTENER=live \
    bash "${PROBE}" --sandbox 8.8.8.8 10.0.0.5
  [ "$status" -eq 1 ]
  python3 -c '
import json, sys
d = json.loads(sys.argv[1].strip().splitlines()[-1])
assert d["ok"] is False
assert d["host_health"] == "reachable"
print("ok")
' "$output"

  run env ISOLATION_CURL="${ROOT}/missing-curl" ISOLATION_HOST_LISTENER=live ISOLATION_LAN_LISTENER=live \
    bash "${PROBE}" --sandbox 8.8.8.8 10.0.0.5
  [ "$status" -eq 1 ]
  python3 -c '
import json, sys
d = json.loads(sys.argv[1].strip().splitlines()[-1])
assert d["ok"] is False
assert d["host_health"] == "inconclusive"
assert d["npm"] == "inconclusive"
assert d["lan"] == "inconclusive"
print("ok")
' "$output"
}

@test "isolation probe rejects NAT private public IP, equal targets, and invalid addresses" {
  run bash "${PROBE}" --sandbox 10.0.0.8 10.0.0.5
  [ "$status" -eq 1 ]
  python3 -c '
import json, sys
d = json.loads(sys.argv[1].strip().splitlines()[-1])
assert d["ok"] is False
assert d["targets_valid"] is False
assert d["public_class"] == "private"
print("ok")
' "$output"

  run bash "${PROBE}" --sandbox 8.8.8.8 8.8.8.8
  [ "$status" -eq 1 ]
  python3 -c '
import json, sys
d = json.loads(sys.argv[1].strip().splitlines()[-1])
assert d["ok"] is False
assert d["targets_valid"] is False
print("ok")
' "$output"

  run bash "${PROBE}" --sandbox not-an-ip 10.0.0.5
  [ "$status" -eq 1 ]
  python3 -c '
import json, sys
d = json.loads(sys.argv[1].strip().splitlines()[-1])
assert d["ok"] is False
assert d["public_class"] == "invalid"
print("ok")
' "$output"
}

@test "isolation probe treats a dead listener as unproven rather than blocked" {
  cat >"${ROOT}/bin/curl-dead" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
  chmod +x "${ROOT}/bin/curl-dead"
  run env ISOLATION_CURL="${ROOT}/bin/curl-dead" bash "${PROBE}" --host-proof 8.8.8.8 10.0.0.5
  [ "$status" -eq 1 ]
  python3 -c '
import json, sys
d = json.loads(sys.argv[1].strip().splitlines()[-1])
assert d["ok"] is False
assert d["host_listener"] == "dead"
print("ok")
' "$output"

  cat >"${ROOT}/bin/curl-sandbox" <<'EOF'
#!/usr/bin/env bash
url=""
for arg in "$@"; do
  case "${arg}" in http*|https*) url="${arg}" ;; esac
done
case "${url}" in
  *8.8.8.8:5008*) exit 28 ;;
  *registry.npmjs.org*) echo -n 200; exit 0 ;;
  *10.0.0.5*) exit 7 ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${ROOT}/bin/curl-sandbox"
  run env ISOLATION_CURL="${ROOT}/bin/curl-sandbox" ISOLATION_HOST_LISTENER=unproven ISOLATION_LAN_LISTENER=live \
    bash "${PROBE}" --sandbox 8.8.8.8 10.0.0.5
  [ "$status" -eq 1 ]
  python3 -c '
import json, sys
d = json.loads(sys.argv[1].strip().splitlines()[-1])
assert d["ok"] is False
assert d["host_health"] == "inconclusive"
print("ok")
' "$output"
}

@test "isolation probe bypasses HTTP proxy environment variables" {
  cat >"${ROOT}/bin/curl-proxy" <<'EOF'
#!/usr/bin/env bash
has_noproxy=0
for arg in "$@"; do
  if [[ "${arg}" == "--noproxy" || "${arg}" == --noproxy=* ]]; then
    has_noproxy=1
  fi
done
if [[ "${has_noproxy}" -ne 1 ]]; then
  echo "proxy-used" >&2
  exit 1
fi
url=""
for arg in "$@"; do
  case "${arg}" in http*|https*) url="${arg}" ;; esac
done
case "${url}" in
  *127.0.0.1:5008*) echo -n 200; exit 0 ;;
  *8.8.8.8:5008*) exit 28 ;;
  *registry.npmjs.org*) echo -n 200; exit 0 ;;
  *10.0.0.5*) exit 7 ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${ROOT}/bin/curl-proxy"
  run env HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9 \
    http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 \
    ISOLATION_CURL="${ROOT}/bin/curl-proxy" ISOLATION_HOST_LISTENER=live ISOLATION_LAN_LISTENER=live \
    bash "${PROBE}" --sandbox 8.8.8.8 10.0.0.5
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"proxy-used"* ]]
}

@test "qops-doctor isolation check fails on inconclusive smoke output" {
  pass_env
  export DOCTOR_SMOKE_JSON='{"ok": true, "echo": "ok", "killed": true, "isolation": {"ok": false, "targets_valid": true, "host_health": "inconclusive", "npm": "inconclusive", "lan": "inconclusive", "host_listener": "live", "lan_listener": "live"}}'
  run bash "${DOCTOR}"
  [ "$status" -eq 1 ]
  python3 - "${ROOT}/doctor.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
iso = next(c for c in r["checks"] if c["id"] == "isolation_probe")
assert iso["passed"] is False, iso
assert "inconclusive" in iso["message"]
print("ok")
PY
}

@test "e2b-smoke with stubbed sandbox commands runs echo, probe, and kill" {
  cat >"${ROOT}/bin/create" <<'EOF'
#!/usr/bin/env bash
echo sbx_test
EOF
  cat >"${ROOT}/bin/execs" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
  cat >"${ROOT}/bin/kill" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat >"${ROOT}/bin/curl-probe" <<'EOF'
#!/usr/bin/env bash
url=""
for arg in "$@"; do
  case "${arg}" in http*|https*) url="${arg}" ;; esac
done
case "${url}" in
  *127.0.0.1:5008*) echo -n 200; exit 0 ;;
  *8.8.4.4:5008*) exit 28 ;;
  *registry.npmjs.org*) echo -n 200; exit 0 ;;
  *10.1.2.3*) exit 7 ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${ROOT}/bin/create" "${ROOT}/bin/execs" "${ROOT}/bin/kill" "${ROOT}/bin/curl-probe"
  run env \
    DOCTOR_SANDBOX_CREATE_CMD="${ROOT}/bin/create" \
    DOCTOR_SANDBOX_EXEC_CMD="${ROOT}/bin/execs" \
    DOCTOR_SANDBOX_KILL_CMD="${ROOT}/bin/kill" \
    DOCTOR_ISOLATION_PROBE_SCRIPT="${PROBE}" \
    DOCTOR_HOST_PUBLIC_IP=8.8.4.4 \
    DOCTOR_LAN_IP=10.1.2.3 \
    DOCTOR_ORCH_HEALTH_URL="http://127.0.0.1:5008/health" \
    DOCTOR_LAN_CONTROL_URL="http://127.0.0.1:5008/health" \
    ISOLATION_CURL="${ROOT}/bin/curl-probe" \
    bash "${SMOKE}"
  echo "$output"
  [ "$status" -eq 0 ]
  python3 -c '
import json, sys
d = json.loads(sys.argv[1].strip().splitlines()[-1])
assert d["ok"] is True
assert d["echo"] == "ok"
assert d["isolation"]["ok"] is True
assert d["killed"] is True
print("ok")
' "$output"
}

@test "malformed truncated and wrong-schema preflight reports fail and continue" {
  pass_env
  cat >"${ROOT}/bin/preflight" <<'EOF'
#!/usr/bin/env bash
printf '{not json' >"${PREFLIGHT_REPORT_PATH}"
exit 0
EOF
  chmod +x "${ROOT}/bin/preflight"
  export DOCTOR_FAIL_UNIT=traefik
  run bash "${DOCTOR}"
  [ "$status" -eq 1 ]
  python3 - "${ROOT}/doctor.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
ids = {c["id"] for c in r["checks"]}
failed = {c["id"] for c in r["checks"] if not c["passed"] and not c.get("skipped")}
assert "preflight" in failed
assert "unit_traefik" in failed
assert "hugepages" in ids
assert "worker_fallback" in ids
print("malformed")
PY

  prepare_world
  pass_env
  cat >"${ROOT}/bin/preflight" <<'EOF'
#!/usr/bin/env bash
printf '{"version":1,"timestamp":"t"' >"${PREFLIGHT_REPORT_PATH}"
exit 0
EOF
  chmod +x "${ROOT}/bin/preflight"
  export DOCTOR_WORKER_LOG="falling back to default"
  run bash "${DOCTOR}"
  [ "$status" -eq 1 ]
  python3 - "${ROOT}/doctor.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
failed = {c["id"] for c in r["checks"] if not c["passed"] and not c.get("skipped")}
assert "preflight" in failed
assert "worker_fallback" in failed
print("truncated")
PY

  prepare_world
  pass_env
  cat >"${ROOT}/bin/preflight" <<'EOF'
#!/usr/bin/env bash
cat >"${PREFLIGHT_REPORT_PATH}" <<'JSON'
{"version": 99, "timestamp": "t", "passed": true, "checks": [], "failures": []}
JSON
exit 0
EOF
  chmod +x "${ROOT}/bin/preflight"
  export DOCTOR_FAIL_UNIT=e2b-api
  run bash "${DOCTOR}"
  [ "$status" -eq 1 ]
  python3 - "${ROOT}/doctor.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
failed = {c["id"] for c in r["checks"] if not c["passed"] and not c.get("skipped")}
pre = next(c for c in r["checks"] if c["id"] == "preflight")
assert pre["passed"] is False
assert "schema" in pre["message"].lower() or "version" in pre["message"].lower()
assert "unit_e2b_api" in failed
print("wrong-schema")
PY
}

@test "nbd.ko check covers every flavor at the newest version including rc kernels" {
  pass_env
  mkdir -p "${ROOT}/modules/6.11.0-generic/kernel" "${ROOT}/modules/6.11.0-1-amd64/kernel"
  touch "${ROOT}/modules/6.11.0-generic/kernel/nbd.ko"
  run bash "${DOCTOR}"
  [ "$status" -eq 1 ]
  python3 - "${ROOT}/doctor.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
nbd = next(c for c in r["checks"] if c["id"] == "nbd_ko_newest_kernel")
assert nbd["passed"] is False, nbd
assert "6.11.0-1-amd64" in nbd["message"], nbd
print("flavor")
PY

  prepare_world
  pass_env
  mkdir -p "${ROOT}/modules/6.12.0-rc1/kernel"
  rm -f "${ROOT}/modules/6.11.0/kernel/nbd.ko"
  touch "${ROOT}/modules/6.8.0/kernel/nbd.ko"
  run bash "${DOCTOR}"
  [ "$status" -eq 1 ]
  python3 - "${ROOT}/doctor.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
nbd = next(c for c in r["checks"] if c["id"] == "nbd_ko_newest_kernel")
assert nbd["passed"] is False, nbd
assert "6.12.0-rc1" in nbd["message"], nbd
print("rc")
PY
}
