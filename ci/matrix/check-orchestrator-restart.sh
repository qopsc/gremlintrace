#!/usr/bin/env bash
# Restart e2b-orchestrator while sandboxes are active; assert no runtime leaks remain.
#
# Requires successful sandbox creation. If the runner cannot create a sandbox,
# this check FAILS (does not pass). Set QOPS_CI_ORCHESTRATOR_RESTART_SKIP_UNVERIFIED=1
# to skip the whole check with an explicit unverified skip.
set -euo pipefail

if [[ "${QOPS_CI_ORCHESTRATOR_RESTART_SKIP_UNVERIFIED:-}" == "1" ]]; then
  echo "orchestrator-restart: SKIP unverified (QOPS_CI_ORCHESTRATOR_RESTART_SKIP_UNVERIFIED=1)" >&2
  exit 0
fi

API_KEY=""
if [[ -f /etc/qops/secrets.env ]]; then
  API_KEY="$(grep -E '^E2B_API_KEY=' /etc/qops/secrets.env | head -n1 | cut -d= -f2- || true)"
fi

if [[ -z "${API_KEY}" ]]; then
  echo "orchestrator-restart: E2B_API_KEY missing; cannot create a sandbox" >&2
  exit 1
fi

create_sandbox() {
  local body
  body="$(curl -fsS -X POST "http://127.0.0.1:8080/sandboxes" \
    -H "X-API-Key: ${API_KEY}" \
    -H 'Content-Type: application/json' \
    -d '{"template":"kodus-sandbox","timeout":300}')"
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d.get("sandboxID") or d.get("sandboxId") or d.get("id") or "")' "${body}"
}

assert_live_runtime() {
  local sbx="$1"
  local found=0
  if ls /run/netns/ns-* >/dev/null 2>&1; then
    found=1
  fi
  if ip -o link show 2>/dev/null | grep -q 'veth-'; then
    found=1
  fi
  if ls /sys/fs/cgroup/e2b/sbx-* >/dev/null 2>&1; then
    found=1
  fi
  if grep -h . /sys/block/nbd*/size 2>/dev/null | grep -qv '^0$'; then
    found=1
  fi
  if [[ "${found}" -eq 0 ]]; then
    echo "orchestrator-restart: sandbox ${sbx} created but no live netns/veth/nbd/cgroup state" >&2
    return 1
  fi
  echo "orchestrator-restart: live runtime observed for ${sbx}"
}

assert_clean_runtime() {
  local leaks=0
  if ls /run/netns/ns-* >/dev/null 2>&1; then
    echo "leak: netns ns-* present" >&2
    ls -la /run/netns/ns-* >&2 || true
    leaks=1
  fi
  if ip -o link show 2>/dev/null | grep -q 'veth-'; then
    echo "leak: veth interfaces present" >&2
    ip -o link show | grep veth >&2 || true
    leaks=1
  fi
  if ls /sys/fs/cgroup/e2b/sbx-* >/dev/null 2>&1; then
    echo "leak: e2b cgroup sbx-* present" >&2
    ls -la /sys/fs/cgroup/e2b/ >&2 || true
    leaks=1
  fi
  if grep -h . /sys/block/nbd*/size 2>/dev/null | grep -qv '^0$'; then
    echo "leak: nbd device in use after restart" >&2
    grep -H . /sys/block/nbd*/size 2>/dev/null >&2 || true
    leaks=1
  fi
  if [[ "${leaks}" -ne 0 ]]; then
    return 1
  fi
}

IDS=()
for _ in 1 2; do
  id="$(create_sandbox)"
  if [[ -z "${id}" ]]; then
    echo "orchestrator-restart: sandbox create returned empty id" >&2
    exit 1
  fi
  IDS+=("${id}")
done

printf 'orchestrator-restart: created sandboxes %s\n' "${IDS[*]}"
for id in "${IDS[@]}"; do
  assert_live_runtime "${id}"
done

sudo systemctl restart e2b-orchestrator.service
sleep 15

assert_clean_runtime

printf 'orchestrator-restart: ok (sandboxes %s; no ns/veth/nbd/cgroup leaks after restart)\n' "${IDS[*]}"
