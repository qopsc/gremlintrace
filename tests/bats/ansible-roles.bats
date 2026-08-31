#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  RENDER="${REPO_ROOT}/tests/fixtures/render-template.sh"
  VARS="${REPO_ROOT}/tests/fixtures/ansible-role-vars.yml"
  export ANSIBLE_CONFIG="${REPO_ROOT}/ansible.cfg"
  export ANSIBLE_ROLES_PATH="${REPO_ROOT}/ansible/roles"
  PREFLIGHT_SCRIPT="${REPO_ROOT}/ansible/roles/preflight/files/run-preflight.sh"
  PREFLIGHT_REPORT="${BATS_TMPDIR}/preflight.json"
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
    PREFLIGHT_DNS_RANDOM_HOST=preflight-check.e2b.fixture.example.com \
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

@test "preflight report lists every failed check in failures summary" {
  run env \
    PREFLIGHT_REPORT_PATH="${PREFLIGHT_REPORT}" \
    PREFLIGHT_MIN_VCPUS=9999 \
    PREFLIGHT_EGRESS_URLS="" \
    bash "${PREFLIGHT_SCRIPT}"
  [ "$status" -eq 1 ]
  run python3 - "${PREFLIGHT_REPORT}" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
failed_messages = {c["message"] for c in report["checks"] if not c["passed"]}
for failure in report["failures"]:
    assert failure in failed_messages
print(len(report["failures"]))
PY
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -ge 2 ]
}

@test "rendered nftables ruleset validates with nft -c -f" {
  nft_out="${BATS_TMPDIR}/qops.nft"
  "${RENDER}" ansible/roles/host_firewall/templates/qops.nft.j2 "${VARS}" >"${nft_out}"
  run sudo /sbin/nft -c -f "${nft_out}"
  [ "$status" -eq 0 ]
  grep -q '10.0.0.0/8' "${nft_out}"
}

@test "nftables template changes when sandbox internal CIDR fixture changes" {
  base="${BATS_TMPDIR}/base.nft"
  changed="${BATS_TMPDIR}/changed.nft"
  "${RENDER}" ansible/roles/host_firewall/templates/qops.nft.j2 "${VARS}" >"${base}"
  "${RENDER}" ansible/roles/host_firewall/templates/qops.nft.j2 "${VARS}" \
    '{"e2b_allow_sandbox_internal_cidrs":["192.168.0.0/16"]}' >"${changed}"
  grep -q '10.0.0.0/8' "${base}"
  grep -q '192.168.0.0/16' "${changed}"
  ! grep -q '192.168.0.0/16' "${base}"
}

@test "docker daemon.json address pools avoid sandbox CIDRs" {
  run python3 - "${VARS}" <<'PY'
import ipaddress, subprocess, sys, yaml
vars = yaml.safe_load(open(sys.argv[1]))
render = subprocess.check_output([
    "bash", "tests/fixtures/render-template.sh",
    "ansible/roles/docker/templates/daemon.json.j2", sys.argv[1],
], text=True, cwd=".")
import json
cfg = json.loads(render)
host = ipaddress.ip_network(vars["sandbox_host_cidr"])
vrt = ipaddress.ip_network(vars["sandbox_vrt_cidr"])
for pool in cfg["default-address-pools"]:
    net = ipaddress.ip_network(pool["base"])
    assert not net.overlaps(host), pool
    assert not net.overlaps(vrt), pool
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "daemon.json template reflects fixture log rotation values" {
  out="${BATS_TMPDIR}/daemon.json"
  "${RENDER}" ansible/roles/docker/templates/daemon.json.j2 "${VARS}" >"${out}"
  grep -q '"max-size": "100m"' "${out}"
  "${RENDER}" ansible/roles/docker/templates/daemon.json.j2 "${VARS}" \
    '{"docker_log_max_size":"50m"}' | grep -q '"max-size": "50m"'
}

@test "e2b-data compose binds every published port to 127.0.0.1 only" {
  out="${BATS_TMPDIR}/compose.yml"
  "${RENDER}" ansible/roles/e2b_datastores/templates/docker-compose.yml.j2 "${VARS}" >"${out}"
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

@test "compose template uses image tags from fixture versions" {
  out="${BATS_TMPDIR}/compose.yml"
  "${RENDER}" ansible/roles/e2b_datastores/templates/docker-compose.yml.j2 "${VARS}" >"${out}"
  grep -q 'postgres:18' "${out}"
  grep -q 'redis:8' "${out}"
  grep -q 'clickhouse/clickhouse-server:25.8.30.16' "${out}"
  grep -q 'otel/opentelemetry-collector-contrib:0.146.0' "${out}"
  "${RENDER}" ansible/roles/e2b_datastores/templates/docker-compose.yml.j2 "${VARS}" \
    '{"e2b_postgres_tag":"17"}' | grep -q 'postgres:17'
}

@test "sysctl template includes ip_forward and fixture swappiness" {
  out="${BATS_TMPDIR}/sysctl.conf"
  "${RENDER}" ansible/roles/common/templates/99-qops-sysctl.conf.j2 "${VARS}" >"${out}"
  grep -q 'net.ipv4.ip_forward = 1' "${out}"
  grep -q 'vm.swappiness = 10' "${out}"
  "${RENDER}" ansible/roles/common/templates/99-qops-sysctl.conf.j2 "${VARS}" \
    '{"common_sysctl_settings":{"vm.swappiness":5,"net.ipv4.ip_forward":1}}' | grep -q 'vm.swappiness = 5'
}

@test "modprobe template carries nbds_max from fixture" {
  out="${BATS_TMPDIR}/nbd.conf"
  "${RENDER}" ansible/roles/e2b_host/templates/modprobe-nbd.conf.j2 "${VARS}" >"${out}"
  grep -q 'nbds_max=4096' "${out}"
  "${RENDER}" ansible/roles/e2b_host/templates/modprobe-nbd.conf.j2 "${VARS}" \
    '{"e2b_host_nbd_max":2048}' | grep -q 'nbds_max=2048'
}

@test "e2b-hugepages unit passes fixture percentage to allocator" {
  out="${BATS_TMPDIR}/e2b-hugepages.service"
  "${RENDER}" ansible/roles/e2b_host/templates/e2b-hugepages.service.j2 "${VARS}" >"${out}"
  grep -q 'E2B_HUGEPAGES_PERCENTAGE=75' "${out}"
  "${RENDER}" ansible/roles/e2b_host/templates/e2b-hugepages.service.j2 "${VARS}" \
    '{"e2b_hugepages_percentage":60}' | grep -q 'E2B_HUGEPAGES_PERCENTAGE=60'
}

@test "otel-collector template binds receivers to 127.0.0.1" {
  out="${BATS_TMPDIR}/otel.yaml"
  "${RENDER}" ansible/roles/e2b_datastores/templates/otel-collector.yaml.j2 "${VARS}" >"${out}"
  grep -q 'endpoint: 127.0.0.1:4317' "${out}"
  grep -q 'endpoint: 127.0.0.1:13133' "${out}"
  ! grep -q '0.0.0.0' "${out}"
}
