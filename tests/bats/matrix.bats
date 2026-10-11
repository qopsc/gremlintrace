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

@test "wildcard DNS survives an out-of-zone query and keeps answering in-zone labels" {
  port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
  # 127.0.0.99 has no listener, so the forward branch fails fast and drops the query.
  python3 "${DNS_PY}" --bind 127.0.0.1 --port "${port}" --address 10.9.8.7 \
    --zone e2b.ci.qops.test --upstream 127.0.0.99 &
  dns_pid=$!
  trap 'kill "${dns_pid}" 2>/dev/null || true' EXIT
  python3 - "${port}" <<'PY'
import socket, struct, sys, time
port = int(sys.argv[1])

def encode(name):
    out = bytearray()
    for part in name.split("."):
        raw = part.encode()
        out.append(len(raw)); out.extend(raw)
    out.append(0)
    return bytes(out)

def query(name, qtype=1):
    qid = b"\x12\x34"
    header = qid + struct.pack("!HHHHH", 0x0100, 1, 0, 0, 0)
    return header + encode(name) + struct.pack("!HH", qtype, 1)

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

def ask(payload, timeout, tries):
    sock.settimeout(timeout)
    for _ in range(tries):
        try:
            sock.sendto(payload, ("127.0.0.1", port))
            data, _ = sock.recvfrom(4096)
            return data
        except TimeoutError:
            time.sleep(0.05)
    return None

in_zone = query("r4nd0mlabel9x.e2b.ci.qops.test")
data = ask(in_zone, 2, 20)
if data is None:
    raise SystemExit("no DNS response for the in-zone label")
assert b"\x0a\x09\x08\x07" in data  # 10.9.8.7

# Out-of-zone: the responder forwards (and here the forward is dropped). A crash
# here is invisible to this query but kills the responder.
sock.settimeout(3.0)
sock.sendto(query("example.invalid"), ("127.0.0.1", port))
try:
    sock.recvfrom(4096)
    raise SystemExit("out-of-zone query was answered; expected a dropped forward")
except TimeoutError:
    pass

data = ask(in_zone, 1.5, 4)
if data is None:
    raise SystemExit("responder died after the forwarded query")
assert b"\x0a\x09\x08\x07" in data
print("ok")
PY
  kill "${dns_pid}" 2>/dev/null || true
  trap - EXIT
}

@test "stage-artifacts prepares the root-owned cache dir with sudo before writing" {
  local script mkdir_line cp_line
  script="${REPO_ROOT}/ci/matrix/stage-artifacts.sh"
  grep -q '^sudo mkdir -p "${STAGE_DIR}"$' "${script}"
  grep -q '^sudo chown "$(id -u):$(id -g)" "${STAGE_DIR}"$' "${script}"
  if grep -q '^mkdir -p "${STAGE_DIR}"$' "${script}"; then
    echo "stage dir must be created with sudo on a clean runner" >&2
    return 1
  fi
  mkdir_line="$(grep -n '^sudo mkdir -p' "${script}" | cut -d: -f1)"
  cp_line="$(grep -n '^cp -f ' "${script}" | cut -d: -f1)"
  [ "${mkdir_line}" -lt "${cp_line}" ]
}

@test "matrix secret reads go through sudo and are never masked with || true" {
  local script
  for script in "${ORCH}" "${WEBHOOK}"; do
    grep -q 'read_secret()' "${script}"
    grep -q 'sudo test -f' "${script}"
    grep -q 'sudo grep -E "\^${key}="' "${script}"
    if grep -n 'grep -E "\^' "${script}" | grep -q '|| true'; then
      echo "secret read must not be masked with || true: ${script}" >&2
      return 1
    fi
    if grep -n 'grep -E "\^' "${script}" | grep -qv 'sudo grep'; then
      echo "secret read must run through sudo: ${script}" >&2
      return 1
    fi
  done
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

@test "matrix secret readers check for passwordless sudo before diagnosing a missing key" {
  local script
  for script in "${ORCH}" "${WEBHOOK}"; do
    grep -q 'sudo -n true' "${script}" || {
      echo "missing sudo -n precheck: ${script}" >&2
      return 1
    }
  done
}
