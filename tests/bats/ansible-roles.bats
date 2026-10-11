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
  [[ "$output" == *"task/handler/meta variable references"* ]]
}

@test "production defaults test fails when a task-only default is removed" {
  run python3 - "${REPO_ROOT}" <<'PY'
import importlib.util
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "resolve_defaults", root / "tests/fixtures/resolve-production-defaults.py"
)
resolve = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resolve)
merged = resolve.merge_production_defaults()
merged.pop("common_qops_config_dir", None)
missing = resolve.unresolved_task_variables(merged)
if "common_qops_config_dir" in missing:
    print("unresolved task variable (no production default): common_qops_config_dir")
    raise SystemExit(1)
print("unexpectedly resolved task variables without common_qops_config_dir")
raise SystemExit(0)
PY
  [ "$status" -ne 0 ]
  [[ "$output" == *"common_qops_config_dir"* ]]
}

@test "helper roles create /usr/local/lib/qops before copying helper scripts" {
  for role in preflight e2b_host e2b_datastores; do
    tasks="${REPO_ROOT}/ansible/roles/${role}/tasks/main.yml"
    dir_line="$(grep -n 'path: /usr/local/lib/qops$' "${tasks}" | head -n 1 | cut -d: -f1)"
    copy_line="$(grep -n 'dest:.*\/usr\/local\/lib\/qops' "${tasks}" | head -n 1 | cut -d: -f1)"
    [ -n "${dir_line}" ]
    [ -n "${copy_line}" ]
    [ "${dir_line}" -lt "${copy_line}" ]
  done
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
for expected in ("resources", "glibc", "kernel_nbd", "egress", "isolation_targets", "webhook_probe_config"):
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
  if ! command -v nft >/dev/null 2>&1; then
    skip "nftables validation requires the nft executable"
  fi
  nft_bin="$(command -v nft)"
  nft_out="${BATS_TMPDIR}/qops.nft"
  "${RENDER}" ansible/roles/host_firewall/templates/qops.nft.j2 "${VARS}" >"${nft_out}"
  run sudo "${nft_bin}" -c -f "${nft_out}"
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

@test "nftables template does not widen host input policy for sandbox internal CIDRs" {
  nft_out="${BATS_TMPDIR}/qops-no-internal.nft"
  render_with_defaults ansible/roles/host_firewall/templates/qops.nft.j2 \
    '{"e2b_allow_sandbox_internal_cidrs":["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16"]}' >"${nft_out}"
  run python3 - "${nft_out}" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
cidrs = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
for cidr in cidrs:
    assert f"ip saddr {cidr} accept" not in text, cidr
    assert re.search(rf"saddr\s+{re.escape(cidr)}\s+accept", text) is None, cidr
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
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
for role in ("preflight", "common", "host_firewall", "docker", "e2b_host", "e2b_datastores", "e2b_services", "e2b_templates", "traefik", "kodus", "backup", "doctor"):
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
  render_with_defaults ansible/roles/e2b_datastores/templates/otel-collector.yaml.j2 '{"e2b_datastores_otel_grpc_port":4320}' | grep -q 'endpoint: 0.0.0.0:4320'
  render_with_defaults ansible/roles/e2b_datastores/templates/otel-collector.yaml.j2 '{"e2b_datastores_otel_health_port":13134}' | grep -q 'endpoint: 0.0.0.0:13134'
  render_with_defaults ansible/roles/e2b_datastores/templates/otel-collector.yaml.j2 '{"e2b_datastores_clickhouse_native_port":9001}' | grep -q 'tcp://clickhouse:9001'
  render_with_defaults ansible/roles/e2b_datastores/templates/otel-collector.yaml.j2 '{"e2b_datastores_clickhouse_db":"metrics"}' | grep -q 'database: metrics'
}

@test "otel collector healthcheck is image-native and receives only ClickHouse secrets" {
  compose="${BATS_TMPDIR}/compose-otel-health.yml"
  otel="${BATS_TMPDIR}/otel-no-debug.yml"
  render_with_defaults ansible/roles/e2b_datastores/templates/docker-compose.yml.j2 >"${compose}"
  render_with_defaults ansible/roles/e2b_datastores/templates/otel-collector.yaml.j2 >"${otel}"
  grep -Fq 'test: ["CMD", "/otelcol-contrib", "validate", "--config=/etc/otel-collector.yaml"]' "${compose}"
  ! grep -q 'env_file:' "${compose}"
  grep -Fq 'E2B_CLICKHOUSE_USERNAME: ${E2B_CLICKHOUSE_USERNAME}' "${compose}"
  grep -Fq 'E2B_CLICKHOUSE_PASSWORD: ${E2B_CLICKHOUSE_PASSWORD}' "${compose}"
  ! grep -q '^  debug:' "${otel}"
  ! grep -q '^    traces:' "${otel}"
  ! grep -q 'exporters: \[debug\]' "${otel}"
}

@test "compose and otel templates derive every image tag port and bind host from variables" {
  run python3 - "${REPO_ROOT}" "${BATS_TMPDIR}" <<'PY'
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
tmpdir = pathlib.Path(sys.argv[2])
render = root / "tests/fixtures/render-template.sh"

def render_template(template_rel: str, extra: dict | None = None) -> str:
    vars_file = tmpdir / "vars.yml"
    merged = {}
    import yaml
    for path in (root / "versions.yml", root / "ansible/group_vars/all.yml"):
        merged.update(yaml.safe_load(path.read_text()) or {})
    for role in ("preflight", "common", "host_firewall", "docker", "e2b_host", "e2b_datastores", "e2b_services", "e2b_templates", "traefik", "kodus", "backup", "doctor"):
        defaults = root / f"ansible/roles/{role}/defaults/main.yml"
        if defaults.is_file():
            merged.update(yaml.safe_load(defaults.read_text()) or {})
    if extra:
        merged.update(extra)
    vars_file.write_text(yaml.safe_dump(merged))
    return subprocess.check_output(
        ["bash", str(render), template_rel, str(vars_file)], text=True, cwd=root,
    )

compose_cases = [
    ("e2b_postgres_image", {"e2b_postgres_image": "postgres-alt"}, "image: postgres-alt:"),
    ("e2b_postgres_tag", {"e2b_postgres_tag": "19"}, ":19"),
    ("e2b_redis_image", {"e2b_redis_image": "redis-alt"}, "image: redis-alt:"),
    ("e2b_redis_tag", {"e2b_redis_tag": "9"}, ":9"),
    ("e2b_clickhouse_image", {"e2b_clickhouse_image": "clickhouse/alt"}, "image: clickhouse/alt:"),
    ("e2b_clickhouse_tag", {"e2b_clickhouse_tag": "26.0.0.0"}, ":26.0.0.0"),
    ("e2b_otel_collector_image", {"e2b_otel_collector_image": "otel/alt"}, "image: otel/alt:"),
    ("e2b_otel_collector_tag", {"e2b_otel_collector_tag": "9.9.9"}, ":9.9.9"),
    ("e2b_datastores_postgres_port", {"e2b_datastores_postgres_port": 5444}, "127.0.0.1:5444:5432"),
    ("e2b_datastores_redis_port", {"e2b_datastores_redis_port": 6380}, "127.0.0.1:6380:6379"),
    ("e2b_datastores_clickhouse_http_port", {"e2b_datastores_clickhouse_http_port": 8124}, "127.0.0.1:8124:8123"),
    ("e2b_datastores_clickhouse_native_port", {"e2b_datastores_clickhouse_native_port": 9001}, "127.0.0.1:9001:9000"),
    ("e2b_datastores_otel_grpc_port", {"e2b_datastores_otel_grpc_port": 4318}, "127.0.0.1:4318:4317"),
    ("e2b_datastores_otel_health_port", {"e2b_datastores_otel_health_port": 13134}, "127.0.0.1:13134:13133"),
    ("e2b_datastores_postgres_bind_host", {"e2b_datastores_postgres_bind_host": "127.0.0.2"}, "127.0.0.2:"),
]

base_compose = render_template("ansible/roles/e2b_datastores/templates/docker-compose.yml.j2")
for name, override, needle in compose_cases:
    out = render_template("ansible/roles/e2b_datastores/templates/docker-compose.yml.j2", override)
    assert out != base_compose, name
    assert needle in out, (name, needle)

otel_cases = [
    ("e2b_datastores_otel_grpc_port", {"e2b_datastores_otel_grpc_port": 4320}, "0.0.0.0:4320"),
    ("e2b_datastores_otel_health_port", {"e2b_datastores_otel_health_port": 13134}, "0.0.0.0:13134"),
    ("e2b_datastores_clickhouse_native_port", {"e2b_datastores_clickhouse_native_port": 9001}, "clickhouse:9001"),
    ("e2b_datastores_clickhouse_db", {"e2b_datastores_clickhouse_db": "metrics"}, "database: metrics"),
]

base_otel = render_template("ansible/roles/e2b_datastores/templates/otel-collector.yaml.j2")
for name, override, needle in otel_cases:
    out = render_template("ansible/roles/e2b_datastores/templates/otel-collector.yaml.j2", override)
    assert out != base_otel, name
    assert needle in out, (name, needle)

print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "verify-fc-artifacts rejects corrupted installed binaries" {
  archive="${BATS_TMPDIR}/fc-artifacts.tar.gz"
  bash "${REPO_ROOT}/tests/fixtures/build-fc-artifacts-fixture.sh" \
    "${archive}" v1.14-0.2.0 vmlinux-test 1.36.1
  fc_root="${BATS_TMPDIR}/fc"
  versions="${fc_root}/versions"
  kernels="${fc_root}/kernels"
  busybox="${fc_root}/busybox"
  bash "${REPO_ROOT}/ansible/roles/e2b_host/files/install-fc-artifacts.sh" \
    "${archive}" "${versions}" "${kernels}" "${busybox}" \
    v1.14-0.2.0 vmlinux-test 1.36.1
  run bash "${REPO_ROOT}/ansible/roles/e2b_host/files/verify-fc-artifacts.sh" \
    "${archive}" "${versions}" "${kernels}" "${busybox}" \
    v1.14-0.2.0 vmlinux-test 1.36.1
  [ "$status" -eq 0 ]
  printf 'corrupted\n' >>"${versions}/v1.14-0.2.0/amd64/firecracker"
  run bash "${REPO_ROOT}/ansible/roles/e2b_host/files/verify-fc-artifacts.sh" \
    "${archive}" "${versions}" "${kernels}" "${busybox}" \
    v1.14-0.2.0 vmlinux-test 1.36.1
  [ "$status" -ne 0 ]
}

@test "e2b-host release defaults and archive checksum verification are wired" {
  grep -Fq 'qops_github_repository: "qopsc/gremlintrace"' \
    "${REPO_ROOT}/ansible/group_vars/all.yml"
  grep -Fq 'e2b_host_fc_artifacts_effective_checksum_url' \
    "${REPO_ROOT}/ansible/roles/e2b_host/tasks/main.yml"
  grep -Fq 'sha256sum' "${REPO_ROOT}/ansible/roles/e2b_host/tasks/main.yml"
}

@test "docker overlap ansible task fails when helper exits non-zero" {
  playbook="${BATS_TMPDIR}/docker-overlap-fail.yml"
  cat >"${playbook}" <<EOF
---
- hosts: localhost
  gather_facts: false
  tasks:
    - name: Validate overlap helper failure fails the play
      ansible.builtin.command:
        cmd: python3 ${REPO_ROOT}/ansible/roles/docker/files/cidr-overlaps.py not-a-cidr 10.11.0.0/16
      register: docker_pool_host_overlap
      changed_when: false
      failed_when: >-
        docker_pool_host_overlap.rc != 0 or
        (docker_pool_host_overlap.stdout | trim) == 'true'
EOF
  run ansible-playbook -i localhost, -c local "${playbook}"
  [ "$status" -ne 0 ]
}

@test "clickhouse TTL helper handles missing table, idempotence, updates, and SQL errors" {
  stub="${REPO_ROOT}/tests/fixtures/stub-docker-compose-clickhouse-ttl.sh"
  script="${REPO_ROOT}/ansible/roles/e2b_datastores/files/e2b-apply-clickhouse-ttl.sh"
  compose="${BATS_TMPDIR}/compose.yml"
  touch "${compose}"
  stub_bin="${BATS_TMPDIR}/bin"
  mkdir -p "${stub_bin}"
  cat >"${stub_bin}/docker" <<EOF
#!/usr/bin/env bash
exec env CLICKHOUSE_TTL_STUB_LOG="${BATS_TMPDIR}/ttl.log" bash "${stub}" "\$@"
EOF
  chmod +x "${stub_bin}/docker" "${stub}"

  export PATH="${stub_bin}:${PATH}"
  : >"${BATS_TMPDIR}/ttl.log"

  export TABLE_EXISTS=0
  run bash "${script}" "${compose}" 30
  [ "$status" -ne 0 ]
  [[ "$output" == *"metrics_gauge_local does not exist"* ]]

  export TABLE_EXISTS=1
  export TTL_GAUGE="toDateTime(TimeUnix) + toIntervalDay(30)"
  export TTL_SUM="toDateTime(TimeUnix) + toIntervalDay(30)"
  run bash "${script}" "${compose}" 30
  [ "$status" -eq 0 ]
  ! grep -q '^ALTER TABLE' "${BATS_TMPDIR}/ttl.log"

  export TTL_GAUGE="toDateTime(TimeUnix) + toIntervalDay(7)"
  export TTL_SUM="toDateTime(TimeUnix) + toIntervalDay(7)"
  : >"${BATS_TMPDIR}/ttl.log"
  run bash "${script}" "${compose}" 30
  [ "$status" -eq 0 ]
  grep -q 'ALTER TABLE metrics_gauge_local' "${BATS_TMPDIR}/ttl.log"
  grep -q 'ALTER TABLE metrics_sum_local' "${BATS_TMPDIR}/ttl.log"

  export SQL_FAIL="Code: 999. DB::Exception: simulated failure"
  : >"${BATS_TMPDIR}/ttl.log"
  run bash "${script}" "${compose}" 30
  [ "$status" -ne 0 ]
}

@test "hugepages allocator validates percentage and page size with stubbed proc paths" {
  script="${REPO_ROOT}/ansible/roles/e2b_host/files/e2b-allocate-hugepages.sh"
  fake="${BATS_TMPDIR}/proc"
  mkdir -p "${fake}/sys/vm"
  cat >"${fake}/meminfo" <<'EOF'
MemTotal:       32768000 kB
Hugepagesize:       2048 kB
EOF
  echo 0 >"${fake}/sys/vm/nr_hugepages"
  echo 0 >"${fake}/sys/vm/nr_overcommit_hugepages"

  run env E2B_HUGEPAGES_PERCENTAGE=80 \
    E2B_HUGEPAGES_MEMINFO="${fake}/meminfo" \
    E2B_HUGEPAGES_NR_HUGEPAGES="${fake}/sys/vm/nr_hugepages" \
    E2B_HUGEPAGES_NR_OVERCOMMIT="${fake}/sys/vm/nr_overcommit_hugepages" \
    bash "${script}"
  [ "$status" -eq 0 ]
  [[ "$(cat "${fake}/sys/vm/nr_hugepages")" -gt 0 ]]

  cat >"${fake}/meminfo" <<'EOF'
MemTotal:       32768000 kB
Hugepagesize:       4096 kB
EOF
  run env E2B_HUGEPAGES_PERCENTAGE=80 \
    E2B_HUGEPAGES_MEMINFO="${fake}/meminfo" \
    E2B_HUGEPAGES_NR_HUGEPAGES="${fake}/sys/vm/nr_hugepages" \
    E2B_HUGEPAGES_NR_OVERCOMMIT="${fake}/sys/vm/nr_overcommit_hugepages" \
    bash "${script}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported Hugepagesize"* ]]

  run env E2B_HUGEPAGES_PERCENTAGE=150 \
    E2B_HUGEPAGES_MEMINFO="${fake}/meminfo" \
    E2B_HUGEPAGES_NR_HUGEPAGES="${fake}/sys/vm/nr_hugepages" \
    E2B_HUGEPAGES_NR_OVERCOMMIT="${fake}/sys/vm/nr_overcommit_hugepages" \
    bash "${script}"
  [ "$status" -ne 0 ]

  cat >"${fake}/meminfo" <<'EOF'
MemTotal:       32768000 kB
Hugepagesize:       2048 kB
EOF
  echo 0 >"${fake}/sys/vm/nr_hugepages"
  echo 0 >"${fake}/sys/vm/nr_overcommit_hugepages"
  echo 0 >"${fake}/sys/vm/nr_hugepages_readback"
  echo 0 >"${fake}/sys/vm/nr_overcommit_readback"
  run env E2B_HUGEPAGES_PERCENTAGE=80 \
    E2B_HUGEPAGES_MEMINFO="${fake}/meminfo" \
    E2B_HUGEPAGES_NR_HUGEPAGES_WRITE="${fake}/sys/vm/nr_hugepages" \
    E2B_HUGEPAGES_NR_HUGEPAGES_READ="${fake}/sys/vm/nr_hugepages_readback" \
    E2B_HUGEPAGES_NR_OVERCOMMIT_WRITE="${fake}/sys/vm/nr_overcommit_hugepages" \
    E2B_HUGEPAGES_NR_OVERCOMMIT_READ="${fake}/sys/vm/nr_overcommit_readback" \
    bash "${script}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"shortfall"* ]]
}

@test "no role runs a command referencing a control-machine-only path" {
  run python3 - "${REPO_ROOT}" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
# role_path and playbook_dir resolve on the CONTROL machine. command/shell/raw
# execute on the managed host and transfer nothing, so a managed-host command
# that interpolates either one fails on every real (non-localhost) target.
CONTROL_ONLY = re.compile(r"\{\{[^}]*\b(role_path|playbook_dir)\b[^}]*\}\}")
EXEC_MODULE = re.compile(r"^\s*(?:-\s+)?(?:ansible\.builtin\.)?(command|shell|raw):\s*$")
ARG_KEY = re.compile(r"^\s*(cmd|_raw_params|argv)\s*:")
NEW_TASK = re.compile(r"^\s*-\s+name:")

bad = []
for path in sorted(root.glob("ansible/roles/*/tasks/*.yml")):
    in_exec = False
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if NEW_TASK.match(line):
            in_exec = False
        if EXEC_MODULE.match(line):
            in_exec = True
            continue
        if in_exec and CONTROL_ONLY.search(line):
            bad.append(f"{path.relative_to(root)}:{lineno}: {line.strip()}")

if bad:
    print("control-machine-only path inside a managed-host command:")
    for entry in bad:
        print("  " + entry)
    raise SystemExit(1)
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "every qops helper a role invokes is installed by some role" {
  run python3 - "${REPO_ROOT}" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
# Only helper *scripts*; /usr/local/lib/qops also holds directories
# (e2b-templates is the template source tree, not a script).
REFERENCED = re.compile(r"/usr/local/lib/qops/([A-Za-z0-9._-]+\.(?:sh|py|mjs))")
task_files = sorted(root.glob("ansible/roles/*/tasks/*.yml"))

installed = set()
for path in task_files:
    text = path.read_text(encoding="utf-8")
    # dest: /usr/local/lib/qops/<name>  and  dest: /usr/local/lib/qops (+ loop of names)
    for match in re.finditer(r"dest:\s*/usr/local/lib/qops/([A-Za-z0-9._-]+)", text):
        installed.add(match.group(1))
    if re.search(r"dest:\s*\"?/usr/local/lib/qops/?\{\{", text) or re.search(
        r"dest:\s*/usr/local/lib/qops/?\s*$", text, re.M
    ):
        for match in re.finditer(r"^\s*-\s+([A-Za-z0-9._-]+\.(?:sh|py|mjs))\s*$", text, re.M):
            installed.add(match.group(1))
        for match in re.finditer(r"src:\s*([A-Za-z0-9._-]+\.(?:sh|py|mjs))", text):
            installed.add(match.group(1))

referenced = {}
for path in task_files:
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        for match in REFERENCED.finditer(line):
            referenced.setdefault(match.group(1), f"{path.relative_to(root)}:{lineno}")

missing = {name: loc for name, loc in referenced.items() if name not in installed}
if missing:
    print("helpers invoked but never installed by any role:")
    for name, loc in sorted(missing.items()):
        print(f"  {name} referenced at {loc}")
    raise SystemExit(1)
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "e2b_host activates the swapfile with swapon, not a swap mount" {
  run python3 - "${REPO_ROOT}/ansible/roles/e2b_host/tasks/main.yml" <<'PY'
import sys, yaml
tasks = yaml.safe_load(open(sys.argv[1]))
names = [t.get("name", "") for t in tasks]
mounts = [t for t in tasks if "ansible.posix.mount" in t and t["ansible.posix.mount"].get("fstype") == "swap"]
assert mounts, "no fstab entry task for the swapfile"
for t in mounts:
    # ansible.posix.mount never runs swapon: state=mounted on fstype=swap
    # executes `mount none` and fails on a real host.
    assert t["ansible.posix.mount"]["state"] == "present", t["name"]
swapon = [t for t in tasks if "swapon" in str(t.get("ansible.builtin.command", ""))]
assert len(swapon) == 1, "expected exactly one swapon task"
task = swapon[0]
assert "when" in task, "swapon must be guarded so re-runs stay idempotent"
assert "proc_swaps" in str(task["when"]), task["when"]
assert names.index(mounts[0]["name"]) < names.index(task["name"])
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "common creates the journald drop-in directory before templating into it" {
  run python3 - "${REPO_ROOT}/ansible/roles/common/tasks/main.yml" <<'PY'
import sys, yaml
tasks = yaml.safe_load(open(sys.argv[1]))
names = [t.get("name", "") for t in tasks]
deploy = next(i for i, t in enumerate(tasks)
              if str(t.get("ansible.builtin.template", {}).get("dest", "")).startswith("/etc/systemd/journald.conf.d/"))
dirs = [i for i, t in enumerate(tasks)
        if t.get("ansible.builtin.file", {}).get("path") == "/etc/systemd/journald.conf.d"
        and t["ansible.builtin.file"].get("state") == "directory"]
assert dirs, "no task creates /etc/systemd/journald.conf.d (noble does not ship it)"
assert dirs[0] < deploy, "directory task must precede the template task"
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "every playbook loads documented defaults under tags: always" {
  # group_vars/all.yml is not adjacent to the inventory or playbook dir, so it
  # only arrives through this include. An untagged include is skipped by
  # --tags <role>, leaving every role variable undefined.
  run python3 - "${REPO_ROOT}" <<'PY'
import pathlib, sys, yaml
root = pathlib.Path(sys.argv[1])
bad = []
seen = 0
for pb in sorted((root / "ansible/playbooks").glob("*.yml")):
    for play in yaml.safe_load(pb.read_text()):
        for task in play.get("pre_tasks", []) or []:
            if "load-defaults" in str(task.get("ansible.builtin.include_tasks", "")):
                seen += 1
                tags = task.get("tags", [])
                if isinstance(tags, str):
                    tags = [tags]
                if "always" not in tags:
                    bad.append(f"{pb.name}: {task.get('name')}")
assert seen >= 7, f"expected load-defaults in every playbook, found {seen}"
if bad:
    print("load-defaults include not tagged always:")
    for b in bad:
        print("  " + b)
    raise SystemExit(1)
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "nftables accepts ICMP and ICMPv6 so neighbour discovery and PMTU keep working" {
  nft_out="${BATS_TMPDIR}/qops-icmp.nft"
  "${RENDER}" ansible/roles/host_firewall/templates/qops.nft.j2 "${VARS}" >"${nft_out}"
  run python3 - "${nft_out}" <<'PY'
import sys
lines = [l.strip() for l in open(sys.argv[1]) if l.strip() and not l.strip().startswith('#')]
icmp = [i for i, l in enumerate(lines) if 'icmp' in l and l.endswith('accept')]
assert icmp, "no icmp accept rule under policy drop"
text = "\n".join(lines[i] for i in icmp)
assert 'ipv6-icmp' in text, "ICMPv6 (ND/RA) must be accepted"
assert ' icmp' in text or 'l4proto { icmp' in text or 'l4proto {icmp' in text, "ICMPv4 must be accepted"
veth_drop = next(i for i, l in enumerate(lines) if 'veth-*' in l and l.endswith('drop'))
assert min(icmp) > veth_drop, "icmp accept must stay below the veth drop so sandboxes cannot ping the host"
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "nftables SSH accept follows ansible_port instead of a hardcoded 22" {
  default_out="${BATS_TMPDIR}/qops-ssh-default.nft"
  custom_out="${BATS_TMPDIR}/qops-ssh-custom.nft"
  render_with_defaults ansible/roles/host_firewall/templates/qops.nft.j2 '{}' >"${default_out}"
  render_with_defaults ansible/roles/host_firewall/templates/qops.nft.j2 '{"ansible_port": 2222}' >"${custom_out}"
  grep -Eq 'tcp dport \{ ?22, 80, 443 ?\} accept' "${default_out}"
  grep -Eq 'tcp dport \{ ?2222, 80, 443 ?\} accept' "${custom_out}"
  ! grep -Eq 'dport \{ ?22,' "${custom_out}"
}

@test "host_firewall owns its ruleset through a flush-free unit, not the distro nftables.service" {
  run python3 - "${REPO_ROOT}" <<'PY'
import pathlib, sys, yaml
root = pathlib.Path(sys.argv[1])
tasks = yaml.safe_load((root / "ansible/roles/host_firewall/tasks/main.yml").read_text())
for t in tasks:
    svc = t.get("ansible.builtin.service") or t.get("ansible.builtin.systemd") or t.get("ansible.builtin.systemd_service") or {}
    name = str(svc.get("name", ""))
    # Ubuntu's nftables.service starts with `flush ruleset` and ExecStop flushes
    # everything, including Docker's and the orchestrator's tables.
    assert not (name.endswith("nftables") and svc.get("enabled") is True and "qops" not in name), t["name"]
    li = t.get("ansible.builtin.lineinfile", {})
    assert "nftables.conf" not in str(li.get("path", "")), "must not include the ruleset from the distro config"
units = [t for t in tasks if "qops-nftables.service" in str(t.get("ansible.builtin.template", {}).get("dest", ""))]
assert units, "no qops-nftables.service unit template task"
enable = [t for t in tasks if "qops-nftables" in str((t.get("ansible.builtin.systemd_service") or t.get("ansible.builtin.systemd") or t.get("ansible.builtin.service") or {}).get("name", ""))]
assert enable and enable[0].get("ansible.builtin.systemd_service", enable[0].get("ansible.builtin.systemd", enable[0].get("ansible.builtin.service")))["enabled"] is True
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
  unit="$(render_with_defaults ansible/roles/host_firewall/templates/qops-nftables.service.j2 '{}')"
  printf '%s\n' "${unit}" | grep -q '^ExecStart=.*nft -f /etc/nftables/qops.nft'
  ! printf '%s\n' "${unit}" | grep -qi 'flush ruleset'
  ! printf '%s\n' "${unit}" | grep -q '^ExecStop='
  printf '%s\n' "${unit}" | grep -q '^Before=.*docker.service'
  printf '%s\n' "${unit}" | grep -q '^RemainAfterExit=yes'
}

@test "docker role flushes its restart handler before later roles start datastores" {
  run python3 - "${REPO_ROOT}/ansible/roles/docker/tasks/main.yml" <<'PY'
import sys, yaml
tasks = yaml.safe_load(open(sys.argv[1]))
# Otherwise `Restart docker` fires at e2b_services' flush, after datastores,
# migrations and the seeder ran, and networks created before the restart use
# Docker's default pools instead of daemon.json.
assert tasks[-1].get("ansible.builtin.meta") == "flush_handlers", tasks[-1].get("name")
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "common loads nf_conntrack at boot and before applying its sysctl keys" {
  run python3 - "${REPO_ROOT}/ansible/roles/common/tasks/main.yml" <<'PY'
import sys, yaml
tasks = yaml.safe_load(open(sys.argv[1]))
names = [t.get("name", "") for t in tasks]
sysctl = next(i for i, t in enumerate(tasks)
              if str(t.get("ansible.builtin.template", {}).get("dest", "")).startswith("/etc/sysctl.d/"))
# systemd-sysctl runs before Docker loads nf_conntrack, so
# net.netfilter.nf_conntrack_max is silently skipped at boot unless the module
# is listed in modules-load.d; the same applies on first install.
persist = [i for i, t in enumerate(tasks)
           if str(t.get("ansible.builtin.copy", {}).get("dest", "")).startswith("/etc/modules-load.d/")
           and "nf_conntrack" in str(t["ansible.builtin.copy"].get("content", ""))]
assert persist, "no /etc/modules-load.d entry for nf_conntrack"
load = [i for i, t in enumerate(tasks)
        if "nf_conntrack" in str(t.get("community.general.modprobe", t.get("ansible.builtin.command", "")))]
assert load, "nf_conntrack is never loaded during the play"
assert max(persist + load) < sysctl, "module load/persist must precede the sysctl deploy"
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "hugepages allocator honours a reserved-RAM floor so the host stack keeps memory" {
  script="${REPO_ROOT}/ansible/roles/e2b_host/files/e2b-allocate-hugepages.sh"
  fake="${BATS_TMPDIR}/proc-reserve"
  mkdir -p "${fake}/sys/vm"
  cat >"${fake}/meminfo" <<'EOF'
MemTotal:       32768000 kB
Hugepagesize:       2048 kB
EOF
  echo 0 >"${fake}/sys/vm/nr_hugepages"
  echo 0 >"${fake}/sys/vm/nr_overcommit_hugepages"
  # 32000 MiB total; upstream reserve would be max(4096, 16%)=5120 MiB. A 12288 MiB
  # floor leaves 19712 MiB -> 9856 pages -> 80/20 split = 7884 / 1971.
  run env E2B_HUGEPAGES_PERCENTAGE=80 E2B_HUGEPAGES_RESERVED_RAM_MB=12288 \
    E2B_HUGEPAGES_MEMINFO="${fake}/meminfo" \
    E2B_HUGEPAGES_NR_HUGEPAGES="${fake}/sys/vm/nr_hugepages" \
    E2B_HUGEPAGES_NR_OVERCOMMIT="${fake}/sys/vm/nr_overcommit_hugepages" \
    bash "${script}"
  echo "${output}"
  [ "$status" -eq 0 ]
  [ "$(cat "${fake}/sys/vm/nr_hugepages")" = "7884" ]
  [ "$(cat "${fake}/sys/vm/nr_overcommit_hugepages")" = "1971" ]
  # the unit carries the operator value and group_vars documents it
  render_with_defaults ansible/roles/e2b_host/templates/e2b-hugepages.service.j2 '{"e2b_hugepages_reserved_ram_mb":16384}' \
    | grep -q '^Environment=E2B_HUGEPAGES_RESERVED_RAM_MB=16384$'
  grep -Eq '^e2b_hugepages_reserved_ram_mb:[[:space:]]*[0-9]+' "${REPO_ROOT}/ansible/group_vars/all.yml"
}

@test "preflight still runs under --check so operators can dry-run before install" {
  run python3 - "${REPO_ROOT}/ansible/roles/preflight/tasks/main.yml" <<'PY'
import sys, yaml
tasks = yaml.safe_load(open(sys.argv[1]))
run = next(t for t in tasks if "run-preflight.sh" in str(t.get("ansible.builtin.command", {}).get("cmd", "")))
install = next(t for t in tasks if "run-preflight.sh" in str(t.get("ansible.builtin.copy", {}).get("src", "")) or "run-preflight.sh" in str(t.get("loop", "")))
# Otherwise --check skips the command, and the slurp of the absent report fails.
assert run.get("check_mode") is False, "run task must set check_mode: false"
assert install.get("check_mode") is False, "helper install must set check_mode: false"
# the directories the copy and the report need must also exist under --check
run_idx = tasks.index(run)
dirs = [t for t in tasks[:run_idx] if t.get("ansible.builtin.file", {}).get("state") == "directory"]
assert dirs, "no directory tasks before the run"
for t in dirs:
    assert t.get("check_mode") is False, f"{t['name']} must set check_mode: false"
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}
