#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  RENDER="${REPO_ROOT}/tests/fixtures/render-template.sh"
  VARS="${REPO_ROOT}/tests/fixtures/ansible-role-vars.yml"
  RESOLVE="${REPO_ROOT}/tests/fixtures/resolve-production-defaults.py"
  export ANSIBLE_CONFIG="${REPO_ROOT}/ansible.cfg"
  export ANSIBLE_ROLES_PATH="${REPO_ROOT}/ansible/roles"
  PREFLIGHT_SCRIPT="${REPO_ROOT}/ansible/roles/preflight/files/run-preflight.sh"
  PREFLIGHT_REPORT="${BATS_TMPDIR}/preflight.json"
}

@test "production defaults resolve for all task-5/6 role templates" {
  run python3 "${RESOLVE}"
  [ "$status" -eq 0 ]
  [[ "$output" == ok:* ]]
}

@test "production defaults test fails when a required default is removed" {
  run python3 - "${REPO_ROOT}" <<'PY'
import pathlib
import subprocess
import sys
import tempfile
import yaml

root = pathlib.Path(sys.argv[1])
merged = {}
for path in (root / "versions.yml", root / "ansible/group_vars/all.yml"):
    merged.update(yaml.safe_load(path.read_text()) or {})
for role in ("preflight", "common", "host_firewall", "docker", "e2b_host", "e2b_datastores"):
    defaults = root / f"ansible/roles/{role}/defaults/main.yml"
    if defaults.is_file():
        merged.update(yaml.safe_load(defaults.read_text()) or {})
merged.pop("common_nofile_limit", None)
with tempfile.NamedTemporaryFile("w", suffix=".yml", delete=False) as handle:
    yaml.safe_dump(merged, handle)
    vars_path = handle.name
env = {"ANSIBLE_CONFIG": str(root / "ansible.cfg"), **dict(__import__("os").environ)}
cmd = [
    "ansible", "localhost", "-c", "local", "-m", "ansible.builtin.template",
    "-a", f"src={root}/ansible/roles/common/templates/90-qops-limits.conf.j2 dest=/tmp/qops-limits-test.conf",
    "-e", f"@{vars_path}",
]
result = subprocess.run(cmd, capture_output=True, text=True, env=env, cwd=root)
print(result.stderr.strip() or result.stdout.strip())
raise SystemExit(result.returncode)
PY
  [ "$status" -ne 0 ]
  [[ "$output" == *"common_nofile_limit"* ]]
}

@test "preflight report schema records multiple failures at once" {
  run env \
    PREFLIGHT_REPORT_PATH="${PREFLIGHT_REPORT}" \
    PREFLIGHT_MIN_VCPUS=9999 \
    PREFLIGHT_MIN_RAM_MB=999999 \
    PREFLIGHT_MIN_DISK_GB=999999 \
    PREFLIGHT_MIN_GLIBC=99.99 \
    PREFLIGHT_MIN_KERNEL=99.99 \
    PREFLIGHT_QOPS_DOMAIN=fixture.example.com \
    PREFLIGHT_DNS_API_HOST=api.e2b.fixture.example.com \
    PREFLIGHT_DNS_RANDOM_HOST="$(openssl rand -hex 8).e2b.fixture.example.com" \
    PREFLIGHT_EGRESS_URLS="" \
    bash "${PREFLIGHT_SCRIPT}"
  [ "$status" -eq 1 ]
  [ -f "${PREFLIGHT_REPORT}" ]
  run python3 - "${PREFLIGHT_REPORT}" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
assert report["version"] == 1
assert report["passed"] is False
assert isinstance(report["checks"], list)
assert isinstance(report["failures"], list)
assert len(report["failures"]) >= 3
failed_ids = {c["id"] for c in report["checks"] if not c["passed"]}
for expected in ("resources", "glibc", "kernel_nbd", "egress"):
    assert expected in failed_ids, expected
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "preflight egress accepts live registry status codes" {
  run python3 - <<'PY'
import subprocess
checks = {
    "https://ghcr.io/": None,
    "https://registry-1.docker.io/v2/": None,
}
for url in checks:
    proc = subprocess.run(
        ["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}", "-L", "-X", "GET", url],
        capture_output=True, text=True, check=True,
    )
    checks[url] = proc.stdout.strip()
assert checks["https://ghcr.io/"] in {"200", "301", "302", "308"}, checks
assert checks["https://registry-1.docker.io/v2/"] in {"401", "200"}, checks
print(checks["https://ghcr.io/"], checks["https://registry-1.docker.io/v2/"])
PY
  [ "$status" -eq 0 ]
  run env \
    PREFLIGHT_REPORT_PATH="${PREFLIGHT_REPORT}" \
    PREFLIGHT_MIN_VCPUS=1 \
    PREFLIGHT_MIN_RAM_MB=1 \
    PREFLIGHT_MIN_DISK_GB=1 \
    PREFLIGHT_DNS_API_HOST=127.0.0.1 \
    PREFLIGHT_DNS_RANDOM_HOST=127.0.0.1 \
    PREFLIGHT_EGRESS_URLS="https://ghcr.io/|https://registry-1.docker.io/v2/" \
    bash "${PREFLIGHT_SCRIPT}"
  [ "$status" -eq 1 ]
  run python3 - "${PREFLIGHT_REPORT}" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
egress = next(c for c in report["checks"] if c["id"] == "egress")
assert egress["passed"] is True, egress
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "rendered nftables ruleset validates with nft -c -f" {
  nft_out="${BATS_TMPDIR}/qops.nft"
  "${RENDER}" ansible/roles/host_firewall/templates/qops.nft.j2 "${VARS}" >"${nft_out}"
  run sudo /sbin/nft -c -f "${nft_out}"
  [ "$status" -eq 0 ]
  ! grep -q 'flush ruleset' "${nft_out}"
}

@test "nftables drops veth traffic to port 22 before general accepts" {
  nft_out="${BATS_TMPDIR}/qops-order.nft"
  "${RENDER}" ansible/roles/host_firewall/templates/qops.nft.j2 "${VARS}" >"${nft_out}"
  run python3 - "${nft_out}" <<'PY'
import sys
lines = [line.strip() for line in open(sys.argv[1]) if line.strip() and not line.strip().startswith('#')]
veth_drop = next(i for i, line in enumerate(lines) if 'veth-*' in line and line.endswith('drop'))
port22 = next(i for i, line in enumerate(lines) if 'dport' in line and '22' in line)
assert veth_drop < port22, (veth_drop, port22, lines)
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "nftables template does not include sandbox internal CIDR host input accepts" {
  nft_out="${BATS_TMPDIR}/qops-no-internal.nft"
  "${RENDER}" ansible/roles/host_firewall/templates/qops.nft.j2 "${VARS}" >"${nft_out}"
  ! grep -q '10.0.0.0/8' "${nft_out}"
}

@test "docker overlap script rejects nested overlap and malformed CIDR" {
  run python3 "${REPO_ROOT}/ansible/roles/docker/files/cidr-overlaps.py" 10.11.5.0/24 10.11.0.0/16
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  run python3 "${REPO_ROOT}/ansible/roles/docker/files/cidr-overlaps.py" not-a-cidr 10.11.0.0/16
  [ "$status" -ne 0 ]
}

@test "docker daemon.json address pools avoid sandbox CIDRs" {
  run python3 - "${REPO_ROOT}" <<'PY'
import ipaddress, subprocess, sys, yaml
root = sys.argv[1]
merged = {}
for path in ("versions.yml", "ansible/group_vars/all.yml"):
    merged.update(yaml.safe_load(open(f"{root}/{path}")))
merged.update(yaml.safe_load(open(f"{root}/ansible/roles/docker/defaults/main.yml")))
with open("/tmp/docker-defaults-vars.yml", "w") as fh:
    yaml.safe_dump(merged, fh)
render = subprocess.check_output([
    "bash", f"{root}/tests/fixtures/render-template.sh",
    "ansible/roles/docker/templates/daemon.json.j2", "/tmp/docker-defaults-vars.yml",
], text=True, cwd=root)
import json
cfg = json.loads(render)
host = ipaddress.ip_network(merged["sandbox_host_cidr"])
vrt = ipaddress.ip_network(merged["sandbox_vrt_cidr"])
for pool in cfg["default-address-pools"]:
    net = ipaddress.ip_network(pool["base"])
    assert not net.overlaps(host), pool
    assert not net.overlaps(vrt), pool
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

render_with_defaults() {
  local template_rel="$1"
  local extra="${2:-}"
  local vars_file="${BATS_TMPDIR}/prod-vars.yml"
  python3 - "${REPO_ROOT}" "${vars_file}" "${extra}" <<'PY'
import json
import pathlib
import sys
import yaml

root = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
extra_raw = sys.argv[3]
merged = {}
for path in (root / "versions.yml", root / "ansible/group_vars/all.yml"):
    merged.update(yaml.safe_load(path.read_text()) or {})
for role in ("preflight", "common", "host_firewall", "docker", "e2b_host", "e2b_datastores"):
    defaults = root / f"ansible/roles/{role}/defaults/main.yml"
    if defaults.is_file():
        merged.update(yaml.safe_load(defaults.read_text()) or {})
if extra_raw:
    merged.update(json.loads(extra_raw))
out.write_text(yaml.safe_dump(merged))
PY
  "${RENDER}" "${template_rel}" "${vars_file}"
}

@test "daemon.json template reflects production default log rotation" {
  out="${BATS_TMPDIR}/daemon.json"
  render_with_defaults ansible/roles/docker/templates/daemon.json.j2 >"${out}"
  grep -q '"max-size": "100m"' "${out}"
  render_with_defaults ansible/roles/docker/templates/daemon.json.j2 '{"docker_log_max_size":"50m"}' | grep -q '"max-size": "50m"'
}

@test "e2b-data compose binds every published port to 127.0.0.1 only" {
  out="${BATS_TMPDIR}/compose.yml"
  render_with_defaults ansible/roles/e2b_datastores/templates/docker-compose.yml.j2 >"${out}"
  run python3 - "${out}" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
ports = re.findall(r'^\s*-\s*"([^"]+)"\s*$', text, re.M)
assert ports, "no port mappings found"
for mapping in ports:
    host = mapping.split(":")[0]
    assert host == "127.0.0.1", mapping
    assert "0.0.0.0" not in mapping
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "compose template postgres volume uses /var/lib/postgresql for postgres 18" {
  out="${BATS_TMPDIR}/compose-pg.yml"
  render_with_defaults ansible/roles/e2b_datastores/templates/docker-compose.yml.j2 >"${out}"
  grep -q 'e2b-postgres-data:/var/lib/postgresql' "${out}"
  ! grep -q '/var/lib/postgresql/data' "${out}"
  render_with_defaults ansible/roles/e2b_datastores/templates/docker-compose.yml.j2 '{"e2b_datastores_postgres_port":5444}' | grep -q '127.0.0.1:5444:5432'
}

@test "sysctl template includes ip_forward from production defaults" {
  out="${BATS_TMPDIR}/sysctl.conf"
  render_with_defaults ansible/roles/common/templates/99-qops-sysctl.conf.j2 >"${out}"
  grep -q 'net.ipv4.ip_forward = 1' "${out}"
  render_with_defaults ansible/roles/common/templates/99-qops-sysctl.conf.j2 \
    '{"common_sysctl_settings":{"vm.swappiness":5,"net.ipv4.ip_forward":1}}' | grep -q 'vm.swappiness = 5'
}

@test "modprobe template carries nbds_max from production defaults" {
  out="${BATS_TMPDIR}/nbd.conf"
  render_with_defaults ansible/roles/e2b_host/templates/modprobe-nbd.conf.j2 >"${out}"
  grep -q 'nbds_max=4096' "${out}"
  render_with_defaults ansible/roles/e2b_host/templates/modprobe-nbd.conf.j2 '{"e2b_host_nbd_max":2048}' | grep -q 'nbds_max=2048'
}

@test "e2b-hugepages unit passes percentage variable to allocator" {
  out="${BATS_TMPDIR}/e2b-hugepages.service"
  render_with_defaults ansible/roles/e2b_host/templates/e2b-hugepages.service.j2 >"${out}"
  grep -q 'E2B_HUGEPAGES_PERCENTAGE=80' "${out}"
  render_with_defaults ansible/roles/e2b_host/templates/e2b-hugepages.service.j2 '{"e2b_hugepages_percentage":60}' | grep -q 'E2B_HUGEPAGES_PERCENTAGE=60'
}

@test "otel-collector binds in-container while compose publishes localhost only" {
  otel="${BATS_TMPDIR}/otel.yaml"
  compose="${BATS_TMPDIR}/compose-otel.yml"
  render_with_defaults ansible/roles/e2b_datastores/templates/otel-collector.yaml.j2 >"${otel}"
  render_with_defaults ansible/roles/e2b_datastores/templates/docker-compose.yml.j2 >"${compose}"
  grep -q 'endpoint: 0.0.0.0:4317' "${otel}"
  grep -q '127.0.0.1:4317:4317' "${compose}"
  ! grep -q '0.0.0.0:4317' "${compose}"
  render_with_defaults ansible/roles/e2b_datastores/templates/docker-compose.yml.j2 '{"e2b_datastores_otel_grpc_port":4318}' | grep -q '127.0.0.1:4318:4317'
}
