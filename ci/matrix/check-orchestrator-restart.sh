#!/usr/bin/env bash
# Restart e2b-orchestrator while sandboxes may be active; assert no runtime leaks remain.
set -euo pipefail

API_KEY=""
if [[ -f /etc/qops/secrets.env ]]; then
  API_KEY="$(grep -E '^E2B_API_KEY=' /etc/qops/secrets.env | head -n1 | cut -d= -f2- || true)"
fi

create_sandbox() {
  if [[ -z "${API_KEY}" ]]; then
    return 0
  fi
  curl -fsS -X POST "http://127.0.0.1:8080/sandboxes" \
    -H "X-API-Key: ${API_KEY}" \
    -H 'Content-Type: application/json' \
    -d '{"template":"kodus-sandbox","timeout":300}' \
    >/dev/null 2>&1 || true
}

create_sandbox
create_sandbox

sudo systemctl restart e2b-orchestrator.service
sleep 15

leaks=0
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
  exit 1
fi

printf 'orchestrator-restart: ok (no ns/veth/nbd/cgroup leaks detected)\n'
