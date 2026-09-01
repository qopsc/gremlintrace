#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PREPARE="${REPO_ROOT}/ci/matrix/prepare-host.sh"
  DNS_PY="${REPO_ROOT}/ci/matrix/wildcard-dns.py"
  WEBHOOK="${REPO_ROOT}/ci/matrix/synthetic-github-webhook.sh"
  ORCH="${REPO_ROOT}/ci/matrix/check-orchestrator-restart.sh"
}

@test "prepare-host uses a wildcard DNS responder, not a fixed preflight-check hosts label" {
  grep -q 'wildcard-dns.py' "${PREPARE}"
  grep -q '10.255.0.1' "${PREPARE}"
  grep -q 'lan-listener.py' "${PREPARE}"
  if grep -q 'preflight-check.e2b' "${PREPARE}"; then
    echo "fixed preflight-check hosts label reintroduced; wildcards cannot be implemented in /etc/hosts" >&2
    return 1
  fi
}

@test "wildcard DNS resolves a random label that is not in /etc/hosts" {
  port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
  python3 "${DNS_PY}" --bind 127.0.0.1 --port "${port}" --address 10.9.8.7 \
    --zone ci.qops.test --zone e2b.ci.qops.test &
  dns_pid=$!
  trap 'kill "${dns_pid}" 2>/dev/null || true' EXIT
  python3 - "${port}" <<'PY'
import socket, struct, sys, time
port = int(sys.argv[1])
label = "r4nd0mlabel9x.e2b.ci.qops.test"

def encode(name):
    out = bytearray()
    for part in name.split("."):
        raw = part.encode()
        out.append(len(raw)); out.extend(raw)
    out.append(0)
    return bytes(out)

qid = b"\x12\x34"
header = qid + struct.pack("!HHHHH", 0x0100, 1, 0, 0, 0)
query = header + encode(label) + struct.pack("!HH", 1, 1)
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(2)
for _ in range(20):
    try:
        sock.sendto(query, ("127.0.0.1", port))
        data, _ = sock.recvfrom(4096)
        break
    except TimeoutError:
        time.sleep(0.05)
else:
    raise SystemExit("no DNS response")
assert data[:2] == qid
assert b"\x0a\x09\x08\x07" in data  # 10.9.8.7
print("ok")
PY
  kill "${dns_pid}" 2>/dev/null || true
  trap - EXIT
}

@test "synthetic webhook fails when the secret is missing" {
  grep -q 'webhook secret missing' "${WEBHOOK}"
  grep -q 'X-Hub-Signature-256' "${WEBHOOK}"
  if grep -q 'if \[\[ -n "${SIG}" \]\]' "${WEBHOOK}"; then
    echo "signature header must always be sent" >&2
    return 1
  fi
}

@test "orchestrator restart requires a real sandbox and does not use || true on create" {
  grep -q 'sandbox create' "${ORCH}"
  if grep -E 'create_sandbox.*\|\| true' "${ORCH}"; then
    echo "sandbox create must not be ignored with || true" >&2
    return 1
  fi
  grep -q 'assert_live_runtime' "${ORCH}"
  grep -q 'QOPS_CI_ORCHESTRATOR_RESTART_SKIP_UNVERIFIED' "${ORCH}"
}
