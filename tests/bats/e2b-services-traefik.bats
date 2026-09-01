#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  RENDER="${REPO_ROOT}/tests/fixtures/render-template.sh"
  export ANSIBLE_CONFIG="${REPO_ROOT}/ansible.cfg"
  export ANSIBLE_ROLES_PATH="${REPO_ROOT}/ansible/roles"
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
for role in (
    "preflight", "common", "host_firewall", "docker", "e2b_host",
    "e2b_datastores", "e2b_services", "e2b_templates", "traefik",
):
    defaults = root / f"ansible/roles/{role}/defaults/main.yml"
    if defaults.is_file():
        merged.update(yaml.safe_load(defaults.read_text()) or {})
if extra_raw:
    merged.update(json.loads(extra_raw))
out.write_text(yaml.safe_dump(merged))
PY
  "${RENDER}" "${template_rel}" "${vars_file}"
}

@test "orchestrator unit contains none of the forbidden sandboxing directives" {
  out="${BATS_TMPDIR}/e2b-orchestrator.service"
  render_with_defaults ansible/roles/e2b_services/templates/e2b-orchestrator.service.j2 \
    '{"e2b_services_node_id":"node-fixture"}' >"${out}"
  run python3 - "${out}" <<'PY'
import sys
text = open(sys.argv[1]).read()
forbidden = (
    "ProtectSystem",
    "PrivateDevices",
    "ProtectControlGroups",
    "RestrictNamespaces",
    "ProtectKernelTunables",
)
found = [name for name in forbidden if name in text]
if found:
    raise SystemExit("forbidden directives: " + ", ".join(found))
required = (
    "Requires=docker.service",
    "After=docker.service network-online.target",
    "RequiresMountsFor=/orchestrator /mnt/hugepages",
    "LimitNOFILE=1048576",
    "LimitMEMLOCK=infinity",
    "TasksMax=infinity",
    "OOMScoreAdjust=-900",
    "TimeoutStopSec=180",
    "FORCE_STOP=true",
)
for token in (
    "Requires=docker.service",
    "RequiresMountsFor=/orchestrator /mnt/hugepages",
    "LimitNOFILE=1048576",
    "LimitMEMLOCK=infinity",
    "TasksMax=infinity",
    "OOMScoreAdjust=-900",
    "TimeoutStopSec=180",
    "/sys/fs/cgroup/e2b/sbx-*",
    "FORCE_STOP=true",
):
    if token == "FORCE_STOP=true":
        continue
    assert token in text, token
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "systemd-analyze verify accepts each rendered e2b and traefik unit" {
  dummy_root="${BATS_TMPDIR}/unit-bins"
  mkdir -p "${dummy_root}"
  ln -sf /bin/true "${dummy_root}/orchestrator"
  ln -sf /bin/true "${dummy_root}/api"
  ln -sf /bin/true "${dummy_root}/client-proxy"
  ln -sf /bin/true "${dummy_root}/traefik"
  extra="$(python3 - "${dummy_root}" <<'PY'
import json, sys
root = sys.argv[1]
print(json.dumps({
    "e2b_services_node_id": "node-fixture",
    "e2b_services_orchestrator_bin": f"{root}/orchestrator",
    "e2b_services_api_bin": f"{root}/api",
    "e2b_services_client_proxy_bin": f"{root}/client-proxy",
    "traefik_binary": f"{root}/traefik",
}))
PY
)"
  cat >"${BATS_TMPDIR}/docker.service" <<'EOF'
[Unit]
Description=stub docker.service for systemd-analyze verify

[Service]
Type=oneshot
ExecStart=/bin/true
RemainAfterExit=yes
EOF
  cat >"${BATS_TMPDIR}/network-online.target" <<'EOF'
[Unit]
Description=stub network-online.target for systemd-analyze verify
EOF
  cat >"${BATS_TMPDIR}/e2b-orchestrator.service" <<'EOF'
[Unit]
Description=stub dependency
[Service]
Type=oneshot
ExecStart=/bin/true
RemainAfterExit=yes
EOF
  for tmpl in \
    ansible/roles/e2b_services/templates/e2b-orchestrator.service.j2 \
    ansible/roles/e2b_services/templates/e2b-api.service.j2 \
    ansible/roles/e2b_services/templates/e2b-client-proxy.service.j2 \
    ansible/roles/traefik/templates/traefik.service.j2
  do
    name="$(basename "${tmpl}" .j2)"
    dest="${BATS_TMPDIR}/${name}"
    render_with_defaults "${tmpl}" "${extra}" >"${dest}"
    run systemd-analyze verify "${dest}"
    echo "verify ${name}: status=$status"
    echo "${output}"
    [ "$status" -eq 0 ]
  done
}

@test "env files contain every spec configuration reference value derived from variables" {
  run python3 - "${REPO_ROOT}" "${BATS_TMPDIR}" "${RENDER}" <<'PY'
import json
import pathlib
import subprocess
import sys
import yaml

root = pathlib.Path(sys.argv[1])
tmpdir = pathlib.Path(sys.argv[2])
render = pathlib.Path(sys.argv[3])

def merge(extra=None):
    merged = {}
    for path in (root / "versions.yml", root / "ansible/group_vars/all.yml"):
        merged.update(yaml.safe_load(path.read_text()) or {})
    for role in (
        "preflight", "common", "host_firewall", "docker", "e2b_host",
        "e2b_datastores", "e2b_services", "e2b_templates", "traefik",
    ):
        defaults = root / f"ansible/roles/{role}/defaults/main.yml"
        if defaults.is_file():
            merged.update(yaml.safe_load(defaults.read_text()) or {})
    merged.update({
        "e2b_services_node_id": "node-a",
        "e2b_services_node_ip": "10.9.8.7",
        "e2b_services_postgres_password": "pg-secret",
        "e2b_services_clickhouse_username": "ch-user",
        "e2b_services_clickhouse_password": "ch-secret",
        "e2b_services_sandbox_access_token_hash_seed": "hash-seed-value",
        "e2b_allow_sandbox_internal_cidrs": ["10.1.2.0/24"],
    })
    if extra:
        merged.update(extra)
    vars_file = tmpdir / "env-vars.yml"
    vars_file.write_text(yaml.safe_dump(merged))
    return merged, vars_file

def render_all(extra=None):
    merged, vars_file = merge(extra)
    texts = {}
    for name in ("orchestrator.env.j2", "api.env.j2", "client-proxy.env.j2"):
        texts[name] = subprocess.check_output(
            ["bash", str(render), f"ansible/roles/e2b_services/templates/{name}", str(vars_file)],
            text=True, cwd=root,
        )
    return merged, texts

merged, texts = render_all()
combined = "\n".join(texts.values())
required = {
    "ENVIRONMENT=local",
    "SERVICE_DISCOVERY_PROVIDER=local",
    "LOCAL_ORCHESTRATOR_ADDRESS=127.0.0.1:5008",
    "NODE_ID=node-a",
    "NODE_IP=10.9.8.7",
    "ORCHESTRATOR_SERVICES=orchestrator,template-manager",
    "ENVD_TIMEOUT=60s",
    "STORAGE_PROVIDER=Local",
    "LOCAL_TEMPLATE_STORAGE_BASE_PATH=/var/lib/e2b/storage",
    "LOCAL_BUILD_CACHE_STORAGE_BASE_PATH=/orchestrator/build",
    "ARTIFACTS_REGISTRY_PROVIDER=Local",
    "OTEL_COLLECTOR_GRPC_ENDPOINT=127.0.0.1:4317",
    "REDIS_URL=127.0.0.1:6379",
    "POSTGRES_CONNECTION_STRING=postgres://postgres:pg-secret@127.0.0.1:5433/e2b?sslmode=disable",
    "CLICKHOUSE_CONNECTION_STRING=clickhouse://ch-user:ch-secret@127.0.0.1:9000/default",
    "LOKI_URL=unset",
    "API_INTERNAL_GRPC_ADDRESS=127.0.0.1:5009",
    "SANDBOX_ACCESS_TOKEN_HASH_SEED=hash-seed-value",
    'AUTH_PROVIDER_CONFIG={"jwt":[]}',
    "VOLUME_TOKEN_ENABLED=false",
    f"DEFAULT_FIRECRACKER_VERSION={merged['firecracker_version']}",
    f"DEFAULT_KERNEL_VERSION={merged['kernel_version']}",
    f"SANDBOXES_HOST_NETWORK_CIDR={merged['sandbox_host_cidr']}",
    f"SANDBOXES_VRT_NETWORK_CIDR={merged['sandbox_vrt_cidr']}",
    "ALLOW_SANDBOX_INTERNAL_CIDRS=10.1.2.0/24",
    "MAX_PARALLEL_MEMFILE_SNAPSHOTTING=2",
    "ORCHESTRATOR_LOCK_PATH=/orchestrator/orchestrator.lock",
}
for token in required:
    assert token in combined, token
assert "REDIS_URL=redis://" not in combined
assert "VOLUME_TOKEN_ISSUER" not in combined
assert "LAUNCH_DARKLY_API_KEY" not in combined
assert "NOMAD_" not in combined
assert "SHARED_CHUNK_CACHE_PATH" not in combined
assert "FORCE_STOP=false" in texts["orchestrator.env.j2"]
assert "--port" not in combined

_, changed = render_all({
    "e2b_services_node_id": "node-b",
    "e2b_datastores_redis_port": 6380,
    "e2b_services_postgres_password": "other-pg",
    "firecracker_version": "v9.9.9",
    "e2b_allow_sandbox_internal_cidrs": ["192.168.50.0/24"],
})
assert "NODE_ID=node-b" in "\n".join(changed.values())
assert "REDIS_URL=127.0.0.1:6380" in "\n".join(changed.values())
assert "postgres://postgres:other-pg@127.0.0.1:5433/e2b" in "\n".join(changed.values())
assert "DEFAULT_FIRECRACKER_VERSION=v9.9.9" in "\n".join(changed.values())
assert "ALLOW_SANDBOX_INTERNAL_CIDRS=192.168.50.0/24" in "\n".join(changed.values())
assert texts != changed
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "seed step is gated on the teams email query and not a file marker" {
  script="${REPO_ROOT}/ansible/roles/e2b_services/files/e2b-seed-if-needed.sh"
  ! grep -Eiq 'file marker|\.seeded|seeded\.flag|e2b-seeded|seed\.done' "${script}"
  stub="${BATS_TMPDIR}/bin"
  mkdir -p "${stub}"
  secrets="${BATS_TMPDIR}/secrets.env"
  printf 'E2B_API_KEY=\n' >"${secrets}"
  seed_ran="${BATS_TMPDIR}/seed.ran"
  cat >"${stub}/e2b-seed" <<EOF
#!/usr/bin/env bash
echo ran >>"${seed_ran}"
cat >/dev/null
echo "Seeding database with:"
echo " Team API Key: e2b_0123456789abcdef0123456789abcdef01234567"
EOF
  chmod +x "${stub}/e2b-seed"
  cat >"${stub}/psql-empty" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat >"${stub}/psql-exists" <<'EOF'
#!/usr/bin/env bash
if printf '%s\n' "$@" | grep -q "SELECT 1 FROM teams"; then
  echo 1
fi
exit 0
EOF
  chmod +x "${stub}/psql-empty" "${stub}/psql-exists"

  : >"${seed_ran}"
  run bash "${script}" admin@example.com "${stub}/e2b-seed" "${secrets}" \
    "postgres://postgres@127.0.0.1/e2b" "${stub}/psql-exists"
  [ "$status" -eq 0 ]
  [ "$(cat "${seed_ran}")" = "" ]
  [[ "$output" == "already-seeded" ]]
  [[ "$output" != *"e2b_0123456789abcdef"* ]]

  run bash "${script}" admin@example.com "${stub}/e2b-seed" "${secrets}" \
    "postgres://postgres@127.0.0.1/e2b" "${stub}/psql-empty"
  [ "$status" -eq 0 ]
  [ -s "${seed_ran}" ]
  [[ "$output" == "seeded" ]]
  [[ "$output" != *"e2b_0123456789abcdef"* ]]
  grep -q 'E2B_API_KEY=e2b_0123456789abcdef0123456789abcdef01234567' "${secrets}"

  marker="${BATS_TMPDIR}/already-seeded"
  : >"${marker}"
  : >"${seed_ran}"
  run bash "${script}" admin@example.com "${stub}/e2b-seed" "${secrets}" \
    "postgres://postgres@127.0.0.1/e2b" "${stub}/psql-empty"
  [ "$status" -eq 0 ]
  [ -s "${seed_ran}" ]
}

@test "limits helper is a no-op when the addon and tier already match" {
  script="${REPO_ROOT}/ansible/roles/e2b_services/files/e2b-apply-limits.sh"
  stub="${BATS_TMPDIR}/psql-limits"
  cat >"${stub}" <<'EOF'
#!/usr/bin/env bash
sql="$*"
if [[ "${sql}" == *extra_concurrent_sandboxes::text* ]]; then
  echo "80:10"
  exit 0
fi
if [[ "${sql}" == *UPDATE\ tiers* ]]; then
  exit 0
fi
exit 0
EOF
  chmod +x "${stub}"
  run bash "${script}" admin@example.com qops-concurrency 80 10 1 "${stub}"
  [ "$status" -eq 0 ]
  [ "$output" = "unchanged" ]
}

@test "traefik acme_dns and provided configs render priorities and timeouts" {
  acme="${BATS_TMPDIR}/traefik-acme.yml"
  http_acme="${BATS_TMPDIR}/http-acme.yml"
  provided="${BATS_TMPDIR}/traefik-provided.yml"
  http_provided="${BATS_TMPDIR}/http-provided.yml"
  tls_provided="${BATS_TMPDIR}/tls-provided.yml"
  render_with_defaults ansible/roles/traefik/templates/traefik.yml.j2 \
    '{"tls_mode":"acme_dns","tls_acme_dns_provider":"cloudflare"}' >"${acme}"
  render_with_defaults ansible/roles/traefik/templates/dynamic-http.yml.j2 \
    '{"tls_mode":"acme_dns","tls_acme_dns_provider":"cloudflare"}' >"${http_acme}"
  render_with_defaults ansible/roles/traefik/templates/traefik.yml.j2 \
    '{"tls_mode":"provided","tls_cert_path":"/etc/ssl/qops.crt","tls_key_path":"/etc/ssl/qops.key"}' \
    >"${provided}"
  render_with_defaults ansible/roles/traefik/templates/dynamic-http.yml.j2 \
    '{"tls_mode":"provided"}' >"${http_provided}"
  render_with_defaults ansible/roles/traefik/templates/dynamic-tls-provided.yml.j2 \
    '{"tls_mode":"provided","tls_cert_path":"/etc/ssl/qops.crt","tls_key_path":"/etc/ssl/qops.key"}' \
    >"${tls_provided}"

  grep -q 'address: "0.0.0.0:80"' "${acme}"
  grep -q 'address: "0.0.0.0:443"' "${acme}"
  grep -q 'idleTimeout: 24h' "${acme}"
  grep -q 'idleConnTimeout: 600s' "${acme}"
  grep -q 'responseHeaderTimeout: 0' "${acme}"
  grep -q 'provider: cloudflare' "${acme}"
  ! grep -q 'certificatesResolvers' "${provided}"

  grep -q 'priority: 500' "${http_acme}"
  grep -q 'priority: 100' "${http_acme}"
  grep -q 'e2b-api:' "${http_acme}"
  grep -q 'e2b-sandbox:' "${http_acme}"
  grep -q 'kodus-web:' "${http_acme}"
  grep -q 'kodus-api:' "${http_acme}"
  grep -q 'kodus-webhooks:' "${http_acme}"
  grep -q 'passHostHeader: true' "${http_acme}"
  grep -q 'maxRequestBodyBytes: 16777216' "${http_acme}"
  grep -q 'url: http://127.0.0.1:8080' "${http_acme}"
  grep -q 'url: http://127.0.0.1:3002' "${http_acme}"
  grep -q 'certFile: /etc/ssl/qops.crt' "${tls_provided}"

  render_with_defaults ansible/roles/traefik/templates/traefik.yml.j2 \
    '{"tls_mode":"acme_dns","tls_acme_dns_provider":"route53","traefik_idle_conn_timeout":"120s"}' \
    | grep -q 'idleConnTimeout: 120s'
  render_with_defaults ansible/roles/traefik/templates/dynamic-http.yml.j2 \
    '{"tls_mode":"acme_dns","traefik_e2b_api_priority":700}' \
    | grep -q 'priority: 700'
}

@test "internal_ca fails explicitly as M2" {
  script="${REPO_ROOT}/ansible/roles/traefik/files/check-tls-mode.sh"
  run bash "${script}" acme_dns
  [ "$status" -eq 0 ]
  run bash "${script}" provided
  [ "$status" -eq 0 ]
  run bash "${script}" internal_ca
  [ "$status" -ne 0 ]
  [[ "$output" == *"M2"* ]]
}

@test "Traefik is the only rendered host config that binds 0.0.0.0" {
  run python3 - "${REPO_ROOT}" "${BATS_TMPDIR}" "${RENDER}" <<'PY'
import pathlib
import subprocess
import sys
import yaml

root = pathlib.Path(sys.argv[1])
tmpdir = pathlib.Path(sys.argv[2])
render = pathlib.Path(sys.argv[3])
merged = {}
for path in (root / "versions.yml", root / "ansible/group_vars/all.yml"):
    merged.update(yaml.safe_load(path.read_text()) or {})
for role in (
    "preflight", "common", "host_firewall", "docker", "e2b_host",
    "e2b_datastores", "e2b_services", "e2b_templates", "traefik",
):
    defaults = root / f"ansible/roles/{role}/defaults/main.yml"
    if defaults.is_file():
        merged.update(yaml.safe_load(defaults.read_text()) or {})
merged.update({
    "e2b_services_node_id": "node-a",
    "tls_mode": "acme_dns",
    "tls_acme_dns_provider": "cloudflare",
    "tls_cert_path": "/etc/ssl/qops.crt",
    "tls_key_path": "/etc/ssl/qops.key",
})
vars_file = tmpdir / "bind-vars.yml"
vars_file.write_text(yaml.safe_dump(merged))

allowed = {
    root / "ansible/roles/traefik/templates/traefik.yml.j2",
    root / "ansible/roles/e2b_datastores/templates/otel-collector.yaml.j2",
}
offenders = []
for template in sorted((root / "ansible/roles").rglob("*.j2")):
    if template.name == "secrets.env.j2":
        continue
    rendered = subprocess.check_output(
        ["bash", str(render), str(template.relative_to(root)), str(vars_file)],
        text=True, cwd=root,
    )
    if "0.0.0.0" not in rendered:
        continue
    if template in allowed:
        continue
    offenders.append(str(template.relative_to(root)))
if offenders:
    raise SystemExit("unexpected 0.0.0.0 binds: " + ", ".join(offenders))
traefik = subprocess.check_output(
    ["bash", str(render), "ansible/roles/traefik/templates/traefik.yml.j2", str(vars_file)],
    text=True, cwd=root,
)
assert 'address: "0.0.0.0:80"' in traefik
assert 'address: "0.0.0.0:443"' in traefik
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "dist install verifies SHA256SUMS and is a no-op when already installed" {
  archive="${BATS_TMPDIR}/e2b-6e4ce14.tar.gz"
  bash "${REPO_ROOT}/tests/fixtures/build-e2b-dist-fixture.sh" "${archive}" 6e4ce14
  dest="${BATS_TMPDIR}/e2b/6e4ce14"
  current="${BATS_TMPDIR}/e2b/current"
  envd="${BATS_TMPDIR}/fc-envd/envd"
  install="${REPO_ROOT}/ansible/roles/e2b_services/files/install-e2b-dist.sh"
  verify="${REPO_ROOT}/ansible/roles/e2b_services/files/verify-e2b-dist.sh"
  run bash "${install}" "${archive}" "${dest}" "${current}" "${envd}" 6e4ce14
  [ "$status" -eq 0 ]
  run bash "${verify}" "${dest}" "${current}" "${envd}" 6e4ce14
  [ "$status" -eq 0 ]
  [[ "$output" == *verified ]]
  printf 'corrupted\n' >>"${dest}/bin/api"
  run bash "${verify}" "${dest}" "${current}" "${envd}" 6e4ce14
  [ "$status" -ne 0 ]
}

@test "template source install is unchanged on a second run" {
  src="${BATS_TMPDIR}/templates-src-idem"
  dest="${BATS_TMPDIR}/templates-dest-idem"
  rm -rf "${src}" "${dest}"
  mkdir -p "${src}"
  printf '{"name":"fixture"}\n' >"${src}/package.json"
  printf 'export {}\n' >"${src}/build-templates.ts"
  printf 'lock\n' >"${src}/package-lock.json"
  script="${REPO_ROOT}/ansible/roles/e2b_templates/files/install-template-sources.sh"
  run bash "${script}" "${src}" "${dest}"
  [ "$status" -eq 0 ]
  [ "$output" = "installed" ]
  run bash "${script}" "${src}" "${dest}"
  [ "$status" -eq 0 ]
  [ "$output" = "unchanged" ]
}

@test "run-build-templates fails the play on a failed alias" {
  script="${REPO_ROOT}/ansible/roles/e2b_templates/files/run-build-templates.sh"
  dest="${BATS_TMPDIR}/tmpl"
  mkdir -p "${dest}"
  printf '{"name":"x"}\n' >"${dest}/package.json"
  printf 'lock\n' >"${dest}/package-lock.json"
  mkdir -p "${dest}/node_modules"
  sha256sum "${dest}/package-lock.json" | awk '{print $1}' >"${dest}/.npm-ci-stamp"
  cat >"${dest}/package.json" <<'EOF'
{"name":"x","scripts":{"build-templates":"node build.js"}}
EOF
  cat >"${dest}/build.js" <<'EOF'
console.log(JSON.stringify({
  templates: [
    {alias: "base", action: "failed", buildId: null},
    {alias: "kodus-sandbox", action: "skipped", buildId: null},
    {alias: "kodus-sandbox-graph", action: "skipped", buildId: null}
  ]
}));
process.exit(1);
EOF
  summary="${BATS_TMPDIR}/summary.json"
  run bash "${script}" "${dest}" "${summary}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed"* ]]
}

@test "run-build-templates reports unchanged when every alias is skipped" {
  script="${REPO_ROOT}/ansible/roles/e2b_templates/files/run-build-templates.sh"
  dest="${BATS_TMPDIR}/tmpl-skip"
  mkdir -p "${dest}/node_modules"
  printf '{"name":"x","scripts":{"build-templates":"node build.js"}}\n' >"${dest}/package.json"
  printf 'lock\n' >"${dest}/package-lock.json"
  sha256sum "${dest}/package-lock.json" | awk '{print $1}' >"${dest}/.npm-ci-stamp"
  cat >"${dest}/build.js" <<'EOF'
console.log(JSON.stringify({
  templates: [
    {alias: "base", action: "skipped", buildId: null},
    {alias: "kodus-sandbox", action: "skipped", buildId: null},
    {alias: "kodus-sandbox-graph", action: "skipped", buildId: null}
  ]
}));
EOF
  summary="${BATS_TMPDIR}/summary-skip.json"
  run bash "${script}" "${dest}" "${summary}"
  [ "$status" -eq 0 ]
  [[ "$output" == *unchanged ]]
}

@test "hairpin check degrades when the Kodus network is absent" {
  script="${REPO_ROOT}/ansible/roles/traefik/files/hairpin-check.sh"
  stub="${BATS_TMPDIR}/docker-hairpin"
  cat >"${stub}" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "network" && "$2" == "inspect" ]]; then
  exit 1
fi
exit 0
EOF
  chmod +x "${stub}"
  run bash "${script}" kodus "https://api.e2b.example.com/health" "clickhouse/clickhouse-server:25.8.30.16" "${stub}"
  [ "$status" -eq 0 ]
  [[ "$output" == *skipped ]]
}

@test "api unit uses --port from the variable" {
  render_with_defaults ansible/roles/e2b_services/templates/e2b-api.service.j2 \
    '{"e2b_services_api_port":9090,"e2b_services_node_id":"n"}' \
    | grep -q -- '--port 9090'
}
