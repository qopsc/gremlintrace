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
    "e2b_datastores", "e2b_services", "e2b_templates", "traefik", "kodus", "backup", "doctor",
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
    "Wants=docker.service",
    "After=docker.service network-online.target",
    "RequiresMountsFor=/orchestrator /mnt/hugepages",
    "LimitNOFILE=1048576",
    "LimitMEMLOCK=infinity",
    "TasksMax=infinity",
    "OOMScoreAdjust=-900",
    "TimeoutStopSec=2160",
    "FORCE_STOP=true",
)
for token in (
    "Wants=docker.service",
    "RequiresMountsFor=/orchestrator /mnt/hugepages",
    "LimitNOFILE=1048576",
    "LimitMEMLOCK=infinity",
    "TasksMax=infinity",
    "OOMScoreAdjust=-900",
    "TimeoutStopSec=2160",
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
  if ! command -v systemd-analyze >/dev/null 2>&1; then
    skip "systemd-analyze validation requires systemd tools"
  fi
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
        "e2b_datastores", "e2b_services", "e2b_templates", "traefik", "kodus", "backup", "doctor",
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
orch, api, proxy = (
    texts["orchestrator.env.j2"],
    texts["api.env.j2"],
    texts["client-proxy.env.j2"],
)
per_file = {
    "orchestrator.env.j2": {
        "ENVIRONMENT=local",
        "SERVICE_DISCOVERY_PROVIDER=local",
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
        "SANDBOX_ACCESS_TOKEN_HASH_SEED=hash-seed-value",
        f"DEFAULT_FIRECRACKER_VERSION={merged['firecracker_version']}",
        f"DEFAULT_KERNEL_VERSION={merged['kernel_version']}",
        f"SANDBOXES_HOST_NETWORK_CIDR={merged['sandbox_host_cidr']}",
        f"SANDBOXES_VRT_NETWORK_CIDR={merged['sandbox_vrt_cidr']}",
        "ALLOW_SANDBOX_INTERNAL_CIDRS=10.1.2.0/24",
        "MAX_PARALLEL_MEMFILE_SNAPSHOTTING=2",
        "ORCHESTRATOR_LOCK_PATH=/orchestrator/orchestrator.lock",
        "FORCE_STOP=false",
    },
    "api.env.j2": {
        "ENVIRONMENT=local",
        "SERVICE_DISCOVERY_PROVIDER=local",
        "LOCAL_ORCHESTRATOR_ADDRESS=127.0.0.1:5008",
        "NODE_ID=node-a",
        "NODE_IP=10.9.8.7",
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
    },
    "client-proxy.env.j2": {
        "ENVIRONMENT=local",
        "SERVICE_DISCOVERY_PROVIDER=local",
        "NODE_ID=node-a",
        "NODE_IP=10.9.8.7",
        "REDIS_URL=127.0.0.1:6379",
        "LOKI_URL=unset",
        "API_INTERNAL_GRPC_ADDRESS=127.0.0.1:5009",
        "OTEL_COLLECTOR_GRPC_ENDPOINT=127.0.0.1:4317",
        "SANDBOX_ACCESS_TOKEN_HASH_SEED=hash-seed-value",
    },
}
forbidden = {
    "orchestrator.env.j2": (
        "LOCAL_ORCHESTRATOR_ADDRESS=",
        "API_INTERNAL_GRPC_ADDRESS=",
        "AUTH_PROVIDER_CONFIG=",
        "VOLUME_TOKEN_ENABLED=",
    ),
    "api.env.j2": (
        "ORCHESTRATOR_SERVICES=",
        "ENVD_TIMEOUT=",
        "FORCE_STOP=",
        "SANDBOXES_HOST_NETWORK_CIDR=",
        "ALLOW_SANDBOX_INTERNAL_CIDRS=",
    ),
    "client-proxy.env.j2": (
        "POSTGRES_CONNECTION_STRING=",
        "CLICKHOUSE_CONNECTION_STRING=",
        "FORCE_STOP=",
        "ORCHESTRATOR_SERVICES=",
        "LOCAL_ORCHESTRATOR_ADDRESS=",
        "AUTH_PROVIDER_CONFIG=",
    ),
}
for name, tokens in per_file.items():
    for token in tokens:
        assert token in texts[name], f"{name} missing {token}"
for name, tokens in forbidden.items():
    for token in tokens:
        assert token not in texts[name], f"{name} must not contain {token}"
combined = "\n".join(texts.values())
assert "REDIS_URL=redis://" not in combined
assert "VOLUME_TOKEN_ISSUER" not in combined
assert "LAUNCH_DARKLY_API_KEY" not in combined
assert "NOMAD_" not in combined
assert "SHARED_CHUNK_CACHE_PATH" not in combined
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
  ! grep -Eiq 'file marker|seeded\.flag|e2b-seeded\.flag|seed\.done|/\.seeded' "${script}"
  stub="${BATS_TMPDIR}/bin"
  mkdir -p "${stub}"
  secrets="${BATS_TMPDIR}/secrets.env"
  printf 'E2B_API_KEY=\n' >"${secrets}"
  export E2B_SEEDED_KEY_FILE="${BATS_TMPDIR}/seeded-api-key"
  rm -f "${E2B_SEEDED_KEY_FILE}" "${E2B_SEEDED_KEY_FILE}.raw"
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
  run env POSTGRES_CONNECTION_STRING="postgres://postgres@127.0.0.1/e2b" \
    bash "${script}" admin@example.com "${stub}/e2b-seed" "${secrets}" "${stub}/psql-exists"
  [ "$status" -ne 0 ]
  [ "$(cat "${seed_ran}")" = "" ]
  [[ "$output" == *"unrecoverable"* ]]

  printf 'E2B_API_KEY=e2b_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' >"${secrets}"
  run env POSTGRES_CONNECTION_STRING="postgres://postgres@127.0.0.1/e2b" \
    bash "${script}" admin@example.com "${stub}/e2b-seed" "${secrets}" "${stub}/psql-exists"
  [ "$status" -eq 0 ]
  [ "$(cat "${seed_ran}")" = "" ]
  [[ "$output" == "already-seeded" ]]
  [[ "$output" != *"e2b_0123456789abcdef"* ]]

  printf 'E2B_API_KEY=\n' >"${secrets}"
  run env POSTGRES_CONNECTION_STRING="postgres://postgres@127.0.0.1/e2b" \
    bash "${script}" admin@example.com "${stub}/e2b-seed" "${secrets}" "${stub}/psql-empty"
  [ "$status" -eq 0 ]
  [ -s "${seed_ran}" ]
  [[ "$output" == "seeded" ]]
  [[ "$output" != *"e2b_0123456789abcdef"* ]]
  grep -q 'E2B_API_KEY=e2b_0123456789abcdef0123456789abcdef01234567' "${secrets}"
  [ "$(cat "${E2B_SEEDED_KEY_FILE}")" = "e2b_0123456789abcdef0123456789abcdef01234567" ]

  marker="${BATS_TMPDIR}/already-seeded"
  : >"${marker}"
  : >"${seed_ran}"
  run env POSTGRES_CONNECTION_STRING="postgres://postgres@127.0.0.1/e2b" \
    bash "${script}" admin@example.com "${stub}/e2b-seed" "${secrets}" "${stub}/psql-empty"
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

  run python3 - "${http_provided}" <<'PY'
import sys
import yaml

routers = yaml.safe_load(open(sys.argv[1]))["http"]["routers"]
assert len(routers) == 5
for name, router in routers.items():
    assert router["tls"] == {}, (name, router.get("tls"))
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]

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
  if grep -E '^[[:space:]]*buffering:' "${http_acme}"; then
    echo "buffering middleware present in acme http config" >&2
    return 1
  fi
  if grep -q 'maxRequestBodyBytes' "${http_acme}"; then
    echo "maxRequestBodyBytes present in acme http config" >&2
    return 1
  fi
  grep -q 'url: http://127.0.0.1:8080' "${http_acme}"
  grep -q 'url: http://127.0.0.1:3002' "${http_acme}"
  grep -q 'certFile: /var/lib/traefik/tls/tls.crt' "${tls_provided}"
  grep -q 'keyFile: /var/lib/traefik/tls/tls.key' "${tls_provided}"

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
    "e2b_datastores", "e2b_services", "e2b_templates", "traefik", "kodus", "backup", "doctor",
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
  dist_version="$(python3 - "${REPO_ROOT}/versions.yml" <<'PY'
import sys, yaml
print(yaml.safe_load(open(sys.argv[1]))["e2b_dist_version"])
PY
)"
  archive="${BATS_TMPDIR}/e2b-${dist_version}.tar.gz"
  bash "${REPO_ROOT}/tests/fixtures/build-e2b-dist-fixture.sh" "${archive}" "${dist_version}"
  dest="${BATS_TMPDIR}/e2b/${dist_version}"
  current="${BATS_TMPDIR}/e2b/current"
  envd="${BATS_TMPDIR}/fc-envd/envd"
  install="${REPO_ROOT}/ansible/roles/e2b_services/files/install-e2b-dist.sh"
  verify="${REPO_ROOT}/ansible/roles/e2b_services/files/verify-e2b-dist.sh"
  patch_name="0001-force-stop-marker.patch"
  patch_sha="4da7ddc0c07cbfd67d1afb0f49dcd4106c48f8bc1907e4c353c92b12d2ff2d9c"
  run bash "${install}" "${archive}" "${dest}" "${current}" "${envd}" "${dist_version}" "${patch_name}" "${patch_sha}"
  [ "$status" -eq 0 ]
  run bash "${verify}" "${dest}" "${current}" "${envd}" "${dist_version}" "${patch_name}" "${patch_sha}"
  [ "$status" -eq 0 ]
  [[ "$output" == *verified ]]
  printf 'corrupted\n' >>"${dest}/bin/api"
  run bash "${verify}" "${dest}" "${current}" "${envd}" "${dist_version}" "${patch_name}" "${patch_sha}"
  [ "$status" -ne 0 ]
}

@test "dist archive sidecar checksum is independent of inner SHA256SUMS" {
  dist_version="6e4ce14"
  archive="${BATS_TMPDIR}/e2b-${dist_version}.tar.gz"
  bash "${REPO_ROOT}/tests/fixtures/build-e2b-dist-fixture.sh" "${archive}" "${dist_version}"
  sidecar="${archive}.sha256"
  (cd "$(dirname "${archive}")" && sha256sum "$(basename "${archive}")") >"${sidecar}"

  run bash -c 'cd "$1" && sha256sum --check "$2"' _ \
    "$(dirname "${archive}")" "$(basename "${sidecar}")"
  [ "$status" -eq 0 ]

  printf 'corrupted\n' >>"${archive}"
  run bash -c 'cd "$1" && sha256sum --check "$2"' _ \
    "$(dirname "${archive}")" "$(basename "${sidecar}")"
  [ "$status" -ne 0 ]
  grep -Fq 'e2b_services_dist_effective_checksum_url' \
    "${REPO_ROOT}/ansible/roles/e2b_services/tasks/fetch-dist.yml"
}

@test "goose migration wrapper keeps the connection string out of argv" {
  script="${REPO_ROOT}/ansible/roles/e2b_services/files/e2b-goose-migrate.sh"
  stub="${BATS_TMPDIR}/goose"
  log="${BATS_TMPDIR}/goose.log"
  migrations="${BATS_TMPDIR}/migrations"
  mkdir -p "${migrations}"
  cat >"${stub}" <<EOF
#!/usr/bin/env bash
if [[ -n "\${GOOSE_DBSTRING:-}" ]]; then
  echo env-ok >>"${log}"
fi
if [[ "\$*" == *postgres://* ]]; then
  echo argv-connection-string >>"${log}"
fi
case "\$*" in
  *status) echo "no migrations" ;;
  *) echo "no migrations" ;;
  esac
EOF
  chmod +x "${stub}"
  : >"${log}"
  run env GOOSE_DBSTRING='postgres://postgres:db-secret@127.0.0.1/e2b' \
    bash "${script}" "${stub}" postgres "${migrations}"
  [ "$status" -eq 0 ]
  [ "$output" = "already-current" ]
  [ "$(grep -c '^env-ok$' "${log}")" -eq 2 ]
  ! grep -q 'connection-string' "${log}"
}

@test "force-stop helper updates the startup env and shutdown marker" {
  script="${REPO_ROOT}/ansible/roles/e2b_services/files/e2b-set-force-stop.sh"
  envfile="${BATS_TMPDIR}/orchestrator.env"
  marker_dir="${BATS_TMPDIR}/orchestrator"
  marker="${marker_dir}/force-stop"
  mkdir -p "${marker_dir}"
  printf 'NODE_ID=node-a\nFORCE_STOP=false\n' >"${envfile}"

  run env QOPS_FORCE_STOP_MARKER="${marker}" bash "${script}" "${envfile}" true
  [ "$status" -eq 0 ]
  grep -q '^FORCE_STOP=true$' "${envfile}"
  [ -f "${marker}" ]

  run env QOPS_FORCE_STOP_MARKER="${marker}" bash "${script}" "${envfile}" false
  [ "$status" -eq 0 ]
  grep -q '^FORCE_STOP=false$' "${envfile}"
  [ ! -e "${marker}" ]
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

@test "seed parse failure keeps raw seeder output and fails loudly" {
  script="${REPO_ROOT}/ansible/roles/e2b_services/files/e2b-seed-if-needed.sh"
  stub="${BATS_TMPDIR}/bin-parse"
  mkdir -p "${stub}"
  secrets="${BATS_TMPDIR}/secrets-parse.env"
  printf 'E2B_API_KEY=\n' >"${secrets}"
  export E2B_SEEDED_KEY_FILE="${BATS_TEST_TMPDIR:-${BATS_TMPDIR}}/seeded-parse"
  rm -f "${E2B_SEEDED_KEY_FILE}" "${E2B_SEEDED_KEY_FILE}.raw" /tmp/seeded-parse.raw
  cat >"${stub}/e2b-seed" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "Team API Key: e2b_NOT_A_VALID_HEX_KEY_AND_MUST_BE_KEPT"
EOF
  cat >"${stub}/psql-empty" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${stub}/e2b-seed" "${stub}/psql-empty"
  run env POSTGRES_CONNECTION_STRING="postgres://postgres@127.0.0.1/e2b" \
    bash "${script}" admin@example.com "${stub}/e2b-seed" "${secrets}" "${stub}/psql-empty"
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not print a Team API Key"* || "$output" == *"failed to parse"* ]]
  if [[ ! -f "${E2B_SEEDED_KEY_FILE}.raw" ]]; then
    echo "missing durable raw capture at ${E2B_SEEDED_KEY_FILE}.raw" >&2
    return 1
  fi
  grep -q 'e2b_NOT_A_VALID_HEX_KEY_AND_MUST_BE_KEPT' "${E2B_SEEDED_KEY_FILE}.raw"
  if grep -q 'e2b_NOT_A_VALID' "${secrets}"; then
    echo "parse failure wrote a key into secrets.env" >&2
    return 1
  fi
}

@test "seed write failure keeps the durable key and fails loudly" {
  script="${REPO_ROOT}/ansible/roles/e2b_services/files/e2b-seed-if-needed.sh"
  stub="${BATS_TMPDIR}/bin-write"
  mkdir -p "${stub}"
  ro="${BATS_TMPDIR}/ro-secrets"
  mkdir -p "${ro}"
  secrets="${ro}/secrets.env"
  printf 'E2B_API_KEY=\n' >"${secrets}"
  chmod 555 "${ro}"
  export E2B_SEEDED_KEY_FILE="${BATS_TEST_TMPDIR:-${BATS_TMPDIR}}/seeded-write"
  rm -f "${E2B_SEEDED_KEY_FILE}" "${E2B_SEEDED_KEY_FILE}.raw"
  cat >"${stub}/e2b-seed" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo " Team API Key: e2b_0123456789abcdef0123456789abcdef01234567"
EOF
  cat >"${stub}/psql-empty" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${stub}/e2b-seed" "${stub}/psql-empty"
  run env POSTGRES_CONNECTION_STRING="postgres://postgres@127.0.0.1/e2b" \
    bash "${script}" admin@example.com "${stub}/e2b-seed" "${secrets}" "${stub}/psql-empty"
  [ "$status" -ne 0 ]
  [ "$(cat "${E2B_SEEDED_KEY_FILE}")" = "e2b_0123456789abcdef0123456789abcdef01234567" ]
  ! grep -q 'e2b_0123456789abcdef0123456789abcdef01234567' "${secrets}"
  chmod 755 "${ro}"
}

@test "seed fails closed on a malformed teams gate query" {
  script="${REPO_ROOT}/ansible/roles/e2b_services/files/e2b-seed-if-needed.sh"
  stub="${BATS_TMPDIR}/bin-malformed"
  mkdir -p "${stub}"
  secrets="${BATS_TMPDIR}/secrets-malformed.env"
  printf 'E2B_API_KEY=\n' >"${secrets}"
  export E2B_SEEDED_KEY_FILE="${BATS_TEST_TMPDIR:-${BATS_TMPDIR}}/seeded-malformed"
  rm -f "${E2B_SEEDED_KEY_FILE}" "${E2B_SEEDED_KEY_FILE}.raw"
  seed_ran="${BATS_TMPDIR}/malformed.ran"
  cat >"${stub}/e2b-seed" <<EOF
#!/usr/bin/env bash
echo ran >>"${seed_ran}"
echo " Team API Key: e2b_0123456789abcdef0123456789abcdef01234567"
EOF
  cat >"${stub}/psql-weird" <<'EOF'
#!/usr/bin/env bash
echo "1 1"
exit 0
EOF
  cat >"${stub}/psql-connfail" <<'EOF'
#!/usr/bin/env bash
echo "could not connect to server" >&2
exit 2
EOF
  chmod +x "${stub}/e2b-seed" "${stub}/psql-weird" "${stub}/psql-connfail"
  : >"${seed_ran}"
  run env POSTGRES_CONNECTION_STRING="postgres://postgres@127.0.0.1/e2b" \
    bash "${script}" admin@example.com "${stub}/e2b-seed" "${secrets}" "${stub}/psql-weird"
  [ "$status" -ne 0 ]
  [ "$(cat "${seed_ran}")" = "" ]
  [[ "$output" == *"unexpected result"* ]]
  ! grep -q 'e2b_0123456789abcdef' "${secrets}"

  run env POSTGRES_CONNECTION_STRING="postgres://postgres@127.0.0.1/e2b" \
    bash "${script}" admin@example.com "${stub}/e2b-seed" "${secrets}" "${stub}/psql-connfail"
  [ "$status" -ne 0 ]
  [ "$(cat "${seed_ran}")" = "" ]
  [[ "$output" == *"refusing to seed"* ]]
}

@test "seed recovers secrets.env from the durable key file" {
  script="${REPO_ROOT}/ansible/roles/e2b_services/files/e2b-seed-if-needed.sh"
  stub="${BATS_TMPDIR}/bin-recover"
  mkdir -p "${stub}"
  secrets="${BATS_TMPDIR}/secrets-recover.env"
  printf 'E2B_API_KEY=\n' >"${secrets}"
  export E2B_SEEDED_KEY_FILE="${BATS_TEST_TMPDIR:-${BATS_TMPDIR}}/seeded-recover"
  printf 'e2b_ffffffffffffffffffffffffffffffffffffffff\n' >"${E2B_SEEDED_KEY_FILE}"
  chmod 600 "${E2B_SEEDED_KEY_FILE}"
  seed_ran="${BATS_TMPDIR}/recover.ran"
  cat >"${stub}/e2b-seed" <<EOF
#!/usr/bin/env bash
echo ran >>"${seed_ran}"
EOF
  cat >"${stub}/psql-exists" <<'EOF'
#!/usr/bin/env bash
echo 1
exit 0
EOF
  chmod +x "${stub}/e2b-seed" "${stub}/psql-exists"
  : >"${seed_ran}"
  run env POSTGRES_CONNECTION_STRING="postgres://postgres@127.0.0.1/e2b" \
    bash "${script}" admin@example.com "${stub}/e2b-seed" "${secrets}" "${stub}/psql-exists"
  [ "$status" -eq 0 ]
  [ "$(cat "${seed_ran}")" = "" ]
  [[ "$output" == "seeded" ]]
  grep -q 'E2B_API_KEY=e2b_ffffffffffffffffffffffffffffffffffffffff' "${secrets}"
}

@test "Traefik executables and cache stay root-owned across a second run" {
  run python3 - "${REPO_ROOT}" <<'PY'
import pathlib
import sys
import yaml

root = pathlib.Path(sys.argv[1])
tasks = yaml.safe_load((root / "ansible/roles/traefik/tasks/main.yml").read_text())
e2b_tasks = yaml.safe_load((root / "ansible/roles/e2b_services/tasks/main.yml").read_text())

def dir_tasks(docs):
    found = []
    stack = list(docs or [])
    while stack:
        item = stack.pop(0)
        if not isinstance(item, dict):
            continue
        block = item.get("ansible.builtin.file") or item.get("file")
        if isinstance(block, dict) and block.get("state") == "directory":
            paths = item.get("loop") or [block.get("path")]
            found.append((block.get("owner"), block.get("mode"), [str(p) for p in paths]))
        for value in item.values():
            if isinstance(value, list):
                stack.extend(value)
    return found

traefik_dirs = dir_tasks(tasks)
e2b_dirs = dir_tasks(e2b_tasks)

def owners_for(entries, needle):
    return [
        (owner, mode, paths)
        for owner, mode, paths in entries
        if any(needle in path for path in paths)
    ]

cache = owners_for(traefik_dirs, "traefik_cache_dir") + owners_for(e2b_dirs, "e2b_services_dist_cache_dir")
assert cache, "cache directory tasks missing"
for owner, _mode, paths in cache:
    assert owner == "root", (owner, paths)

install = owners_for(traefik_dirs, "traefik_install_dir")
assert install, "install dir task missing"
assert all(owner == "root" for owner, _mode, _paths in install)

config = owners_for(traefik_dirs, "traefik_config_dir")
assert config, "config dir task missing"
assert all(owner == "root" for owner, _mode, _paths in config)

state = owners_for(traefik_dirs, "traefik_state_dir")
assert state, "state dir task missing"
assert all(owner == "{{ traefik_user }}" for owner, _mode, _paths in state)
assert all(mode == "0750" for _owner, mode, _paths in state)

working = owners_for(e2b_dirs, "e2b_services_template_storage_path") + owners_for(
    e2b_dirs, "e2b_services_build_cache_path"
)
assert working, "e2b working directory tasks missing"
assert all(owner == "{{ e2b_services_user }}" for owner, _mode, _paths in working)
assert all(mode == "0750" for _owner, mode, _paths in working)

# Second-run stability: both roles declare the same owner for /var/cache/qops.
traefik_cache_owners = {owner for owner, _mode, _paths in owners_for(traefik_dirs, "traefik_cache_dir")}
e2b_cache_owners = {owner for owner, _mode, _paths in owners_for(e2b_dirs, "e2b_services_dist_cache_dir")}
assert traefik_cache_owners == {"root"}
assert e2b_cache_owners == {"root"}
assert traefik_cache_owners == e2b_cache_owners

unit = (root / "ansible/roles/traefik/templates/traefik.service.j2").read_text()
assert "EnvironmentFile=-{{ common_qops_secrets_file" not in unit
assert "EnvironmentFile=-/etc/qops/secrets.env" not in unit
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "nftables does not accept E2B service ports from a non-loopback non-veth source" {
  nft_out="${BATS_TMPDIR}/qops-e2b-ports.nft"
  render_with_defaults ansible/roles/host_firewall/templates/qops.nft.j2 >"${nft_out}"
  run python3 - "${nft_out}" <<'PY'
import re
import sys

text = open(sys.argv[1]).read()
assert "policy drop" in text
ports = (5007, 5008, 8080, 5009, 3002, 3003)
# Strip comments.
lines = []
for raw in text.splitlines():
    line = raw.split("#", 1)[0].strip()
    if line:
        lines.append(line)

def mentions_port(line, port):
    if re.search(rf"\b{port}\b", line) is None:
        return False
    return "dport" in line or "tcp" in line

offenders = []
for line in lines:
    if "accept" not in line:
        continue
    lo_or_veth = ('iif "lo"' in line) or ('iifname "veth-' in line) or ("iif lo" in line)
    for port in ports:
        if mentions_port(line, port) and not lo_or_veth:
            offenders.append((port, line))
    # A bare "tcp dport { ... }" accept on the public input path.
    if "iif" not in line:
        for port in ports:
            if mentions_port(line, port):
                offenders.append((port, line))

if offenders:
    raise SystemExit("E2B ports accepted from non-loopback/non-veth: " + repr(offenders))
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "template sources are packed on the controller and shipped before any host command" {
  run python3 - "${REPO_ROOT}" <<'PY'
import pathlib
import sys
import yaml

root = pathlib.Path(sys.argv[1])
defaults = yaml.safe_load((root / "ansible/roles/e2b_templates/defaults/main.yml").read_text())
assert "playbook_dir" not in str(defaults["e2b_templates_src_dir"])
assert "playbook_dir" in str(defaults["e2b_templates_controller_src_dir"])
assert "e2b_templates_src_dir" in str(defaults["e2b_templates_src_tarball"])
tasks = yaml.safe_load((root / "ansible/roles/e2b_templates/tasks/main.yml").read_text())
names = [t.get("name", "") for t in tasks]
pack = next(i for i, t in enumerate(tasks)
            if "e2b_templates_controller_src_dir" in str((t.get("ansible.builtin.script") or {}).get("cmd", "")))
ship = next(i for i, t in enumerate(tasks)
            if "e2b_templates_src_tarball" in str((t.get("ansible.builtin.copy") or {}).get("dest", "")))
install = next(i for i, t in enumerate(tasks)
               if "install-template-sources.sh" in str((t.get("ansible.builtin.command") or {}).get("cmd", "")))
install_cmd = tasks[install]["ansible.builtin.command"]["cmd"]
assert pack < ship < install, (names[pack], names[ship], names[install])
assert "e2b_templates_src_tarball" in install_cmd
assert "playbook_dir" not in install_cmd
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "template image pruner retains templateId:buildId and fails on rmi error" {
  script="${REPO_ROOT}/ansible/roles/e2b_templates/files/prune-stale-template-images.sh"
  summary="${BATS_TMPDIR}/prune-summary.json"
  cat >"${summary}" <<'EOF'
{
  "templates": [
    {"alias": "base", "templateId": "tpl_base", "action": "built", "buildId": "new1"},
    {"alias": "kodus-sandbox", "templateId": "tpl_ks", "action": "built", "buildId": "new2"}
  ]
}
EOF
  stub="${BATS_TMPDIR}/docker-prune"
  removed="${BATS_TMPDIR}/removed.list"
  : >"${removed}"
  cat >"${stub}" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "images" ]]; then
  printf '%s\n' 'tpl_base:old1' 'tpl_base:new1' 'base:old1' 'tpl_ks:new2'
  exit 0
fi
if [[ "\$1" == "rmi" ]]; then
  echo "\$3" >>"${removed}"
  exit 0
fi
exit 0
EOF
  chmod +x "${stub}"
  run bash "${script}" "${summary}" "${stub}"
  [ "$status" -eq 0 ]
  [ "$output" = "changed" ]
  [ "$(cat "${removed}")" = "tpl_base:old1" ]

  cat >"${stub}" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "images" ]]; then
  printf '%s\n' 'tpl_base:old1' 'tpl_base:new1'
  exit 0
fi
if [[ "\$1" == "rmi" ]]; then
  echo "rmi failed" >&2
  exit 17
fi
exit 0
EOF
  chmod +x "${stub}"
  run bash "${script}" "${summary}" "${stub}"
  [ "$status" -ne 0 ]
}

@test "hairpin required gate fails when the Kodus network is absent" {
  script="${REPO_ROOT}/ansible/roles/traefik/files/hairpin-check.sh"
  stub="${BATS_TMPDIR}/docker-hairpin-req"
  cat >"${stub}" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "network" && "$2" == "inspect" ]]; then
  exit 1
fi
exit 0
EOF
  chmod +x "${stub}"
  export TRAEFIK_HAIRPIN_REQUIRED=1
  run bash "${script}" kodus \
    "https://api.e2b.example.com/health" "clickhouse/clickhouse-server:25.8.30.16" "${stub}"
  unset TRAEFIK_HAIRPIN_REQUIRED
  [ "$status" -ne 0 ]
  [[ "$output" != *ready ]]
}

@test "hairpin check requires HTTP 200 and retries TLS readiness" {
  script="${REPO_ROOT}/ansible/roles/traefik/files/hairpin-check.sh"
  stub="${BATS_TMPDIR}/docker-hairpin-200"
  nfile="${BATS_TMPDIR}/hairpin-n"
  echo 0 >"${nfile}"
  cat >"${stub}" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "network" && "\$2" == "inspect" ]]; then
  exit 0
fi
n="\$(cat "${nfile}")"
n=\$((n + 1))
echo "\$n" >"${nfile}"
if [[ "\$n" -lt 2 ]]; then
  echo "wget: TLS handshake timeout" >&2
  exit 1
fi
echo "HTTP/1.1 200 OK"
echo body
exit 0
EOF
  chmod +x "${stub}"
  export TRAEFIK_HAIRPIN_RETRIES=3 TRAEFIK_HAIRPIN_DELAY=0
  run bash "${script}" kodus \
    "https://api.e2b.example.com/health" "clickhouse/clickhouse-server:25.8.30.16" "${stub}"
  [ "$status" -eq 0 ]
  [[ "$output" == *ready ]]

  cat >"${stub}" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "network" && "$2" == "inspect" ]]; then
  exit 0
fi
echo "HTTP/1.1 404 Not Found"
echo "not the health page"
exit 0
EOF
  chmod +x "${stub}"
  # Only the required gate (site.yml after kodus, doctor.yml) fails on a
  # non-200; the first-install pass degrades to skipped.
  export TRAEFIK_HAIRPIN_RETRIES=1 TRAEFIK_HAIRPIN_DELAY=0 TRAEFIK_HAIRPIN_REQUIRED=1
  run bash "${script}" kodus \
    "https://api.e2b.example.com/health" "clickhouse/clickhouse-server:25.8.30.16" "${stub}"
  unset TRAEFIK_HAIRPIN_REQUIRED
  [ "$status" -ne 0 ]
  [[ "$output" == *"HTTP 200"* ]]
}

@test "hairpin gate is invoked after kodus in site.yml and from doctor.yml" {
  run python3 - "${REPO_ROOT}" <<'PY'
import pathlib
import sys
import yaml

root = pathlib.Path(sys.argv[1])
site = yaml.safe_load((root / "ansible/playbooks/site.yml").read_text())
assert isinstance(site, list) and len(site) >= 2
first, second = site[0], site[1]
roles = first["roles"]
names = []
for item in roles:
    if isinstance(item, str):
        names.append(item)
    elif isinstance(item, dict):
        names.append(item.get("role"))
assert names[-1] == "kodus", names
assert names.index("traefik") < names.index("kodus")
tasks = first.get("tasks") or []
assert tasks, "hairpin must run in the first play after the kodus role"
hairpin = tasks[0]
inc = hairpin.get("ansible.builtin.include_role") or {}
assert inc.get("name") == "traefik"
assert inc.get("tasks_from") == "hairpin.yml"
assert hairpin.get("vars", {}).get("traefik_hairpin_required") is True
second_roles = [
    (item.get("role") if isinstance(item, dict) else item)
    for item in second["roles"]
]
assert second_roles == ["backup", "doctor"]

doctor = yaml.safe_load((root / "ansible/playbooks/doctor.yml").read_text())
blob = yaml.dump(doctor)
assert "hairpin.yml" in blob
assert "traefik_hairpin_required" in blob
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "Traefik unit loads only the dedicated ACME env file" {
  unit="$(render_with_defaults ansible/roles/traefik/templates/traefik.service.j2 '{}')"
  [[ "${unit}" == *traefik-acme.env* ]]
  ! printf '%s\n' "${unit}" | grep -q '^EnvironmentFile=.*secrets.env'
}

# Credentials arrive as a JSON object on stdin (from tls_acme_dns_credentials,
# decrypted on the controller by community.sops). Nothing is read from
# /etc/qops/secrets.env and no value ever appears on argv.
acme_script="ansible/roles/traefik/files/install-traefik-acme-env.sh"

@test "ACME env installer writes only the provider's keys from stdin credentials" {
  script="${REPO_ROOT}/${acme_script}"
  dest="${BATS_TMPDIR}/acme-stdin/traefik-acme.env"
  rm -rf "$(dirname "${dest}")"
  run bash -c 'printf "%s" "$1" | bash "$2" "$3" porkbun' _ \
    '{"PORKBUN_API_KEY":"porkbun-api-key","PORKBUN_SECRET_API_KEY":"porkbun-secret-key"}' \
    "${script}" "${dest}"
  echo "${output}"
  [ "$status" -eq 0 ]
  [ "$output" = "installed" ]
  [ "$(stat -f '%Lp' "${dest}" 2>/dev/null || stat -c '%a' "${dest}")" = "600" ]
  grep -q '^PORKBUN_API_KEY=porkbun-api-key$' "${dest}"
  grep -q '^PORKBUN_SECRET_API_KEY=porkbun-secret-key$' "${dest}"
  [ "$(wc -l <"${dest}" | tr -d ' ')" = "2" ]
}

@test "ACME env installer reports unchanged when the credentials did not change" {
  script="${REPO_ROOT}/${acme_script}"
  dest="${BATS_TMPDIR}/acme-idem/traefik-acme.env"
  rm -rf "$(dirname "${dest}")"
  printf '%s' '{"CF_DNS_API_TOKEN":"cf-token"}' | bash "${script}" "${dest}" cloudflare >/dev/null
  run bash -c 'printf "%s" "$1" | bash "$2" "$3" cloudflare' _ '{"CF_DNS_API_TOKEN":"cf-token"}' "${script}" "${dest}"
  [ "$status" -eq 0 ]
  [ "$output" = "unchanged" ]
  run bash -c 'printf "%s" "$1" | bash "$2" "$3" cloudflare' _ '{"CF_DNS_API_TOKEN":"rotated"}' "${script}" "${dest}"
  [ "$status" -eq 0 ]
  [ "$output" = "installed" ]
  grep -q '^CF_DNS_API_TOKEN=rotated$' "${dest}"
}

@test "ACME env installer rejects keys the provider does not use and never echoes values" {
  script="${REPO_ROOT}/${acme_script}"
  dest="${BATS_TMPDIR}/acme-badkey/traefik-acme.env"
  rm -rf "$(dirname "${dest}")"
  run bash -c 'printf "%s" "$1" | bash "$2" "$3" porkbun' _ \
    '{"PORKBUN_API_KEY":"pk","E2B_API_KEY":"e2b_leaked_value"}' "${script}" "${dest}"
  [ "$status" -ne 0 ]
  [[ "${output}" == *"E2B_API_KEY"* ]]
  [[ "${output}" == *"porkbun"* ]]
  [[ "${output}" == *"PORKBUN_SECRET_API_KEY"* ]]
  [[ "${output}" != *"e2b_leaked_value"* ]]
  [ ! -e "${dest}" ]
  # extra keys for providers outside the built-in table are allowed explicitly
  run bash -c 'printf "%s" "$1" | bash "$2" "$3" exoticdns MY_DNS_TOKEN' _ \
    '{"MY_DNS_TOKEN":"tok"}' "${script}" "${dest}"
  [ "$status" -eq 0 ]
  grep -q '^MY_DNS_TOKEN=tok$' "${dest}"
}

@test "ACME env installer rejects empty credentials with a message naming the expected keys" {
  script="${REPO_ROOT}/${acme_script}"
  dest="${BATS_TMPDIR}/acme-empty/traefik-acme.env"
  rm -rf "$(dirname "${dest}")"
  run bash -c 'printf "%s" "$1" | bash "$2" "$3" porkbun' _ '{}' "${script}" "${dest}"
  [ "$status" -ne 0 ]
  [[ "${output}" == *"no ACME DNS credentials for provider 'porkbun'"* ]]
  [[ "${output}" == *"tls_acme_dns_credentials"* ]]
  [ ! -e "${dest}" ]
}

@test "traefik role feeds tls_acme_dns_credentials to the installer on stdin after a readable assert" {
  run python3 - "${REPO_ROOT}/ansible/roles/traefik/tasks/main.yml" <<'PY'
import sys, yaml
tasks = yaml.safe_load(open(sys.argv[1]))
names = [t.get("name", "") for t in tasks]
cmd_idx = next(i for i, t in enumerate(tasks)
               if "install-traefik-acme-env.sh" in str(t.get("ansible.builtin.command", {}).get("cmd", ""))
               and "--check-keys" not in str(t["ansible.builtin.command"]["cmd"]))
task = tasks[cmd_idx]
cmd = task["ansible.builtin.command"]
assert "secrets_file" not in cmd["cmd"] and "secrets.env" not in cmd["cmd"], cmd["cmd"]
assert "tls_acme_dns_credentials" in str(cmd.get("stdin", "")), "credentials must go in on stdin"
assert task.get("no_log") is True
assert task.get("notify") in ("Restart traefik", ["Restart traefik"]), "credential change must restart traefik"
assert "unchanged" not in str(task.get("changed_when")) or "installed" in str(task.get("changed_when"))
# A non-secret assert before the command gives the operator a readable failure
# (the command itself is no_log).
asserts = [i for i, t in enumerate(tasks[:cmd_idx])
           if "ansible.builtin.assert" in t and "tls_acme_dns_credentials" in str(t["ansible.builtin.assert"])]
assert asserts, "no readable assert on tls_acme_dns_credentials before the no_log command"
fail_msg = str(tasks[asserts[-1]]["ansible.builtin.assert"].get("fail_msg", ""))
assert "sops" in fail_msg.lower() and "tls_acme_dns_provider" in fail_msg, fail_msg
assert "{{ tls_acme_dns_credentials" not in fail_msg, "fail_msg must not print credential values"
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "rendered e2b-api router has no buffering middleware" {
  http_acme="${BATS_TMPDIR}/http-nobuf.yml"
  render_with_defaults ansible/roles/traefik/templates/dynamic-http.yml.j2 \
    '{"tls_mode":"acme_dns","tls_acme_dns_provider":"cloudflare"}' >"${http_acme}"
  if grep -E '^[[:space:]]*buffering:' "${http_acme}"; then
    echo "buffering middleware present" >&2
    return 1
  fi
  if grep -q 'maxRequestBodyBytes' "${http_acme}"; then
    echo "maxRequestBodyBytes present (buffering body limit)" >&2
    return 1
  fi
  grep -q 'e2b-api:' "${http_acme}"
}

@test "provided TLS helper rejects missing files" {
  script="${REPO_ROOT}/ansible/roles/traefik/files/check-provided-tls.sh"
  run bash "${script}" "${BATS_TMPDIR}/missing.crt" "${BATS_TMPDIR}/missing.key"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing"* ]]
  cert="${BATS_TMPDIR}/ok.crt"
  key="${BATS_TMPDIR}/ok.key"
  printf 'cert\n' >"${cert}"
  printf 'key\n' >"${key}"
  run bash "${script}" "${cert}" "${key}"
  [ "$status" -eq 0 ]
}

@test "verify-traefik requires a parsed version exactly matching traefik_version" {
  script="${REPO_ROOT}/ansible/roles/traefik/files/verify-traefik.sh"
  bad="${BATS_TMPDIR}/traefik-bad"
  cat >"${bad}" <<'EOF'
#!/usr/bin/env bash
# Exits 0 with no recognisable version (the skip-install footgun).
exit 0
EOF
  chmod +x "${bad}"
  run bash "${script}" "${bad}" v3.3.4
  [ "$status" -ne 0 ]
  [[ "$output" == *"<empty>"* || "$output" == *"expected"* ]]

  mismatch="${BATS_TMPDIR}/traefik-mismatch"
  cat >"${mismatch}" <<'EOF'
#!/usr/bin/env bash
echo "Version: 9.9.9"
exit 0
EOF
  chmod +x "${mismatch}"
  run bash "${script}" "${mismatch}" v3.3.4
  [ "$status" -ne 0 ]

  good="${BATS_TMPDIR}/traefik-good"
  cat >"${good}" <<'EOF'
#!/usr/bin/env bash
echo "Version: 3.3.4"
exit 0
EOF
  chmod +x "${good}"
  run bash "${script}" "${good}" v3.3.4
  [ "$status" -eq 0 ]
  [[ "$output" == *verified ]]
}

@test "Traefik idleConnTimeout and body-size bounds are enforced" {
  script="${REPO_ROOT}/ansible/roles/traefik/files/validate-traefik-limits.py"
  run python3 "${script}" 600s 16777216 610s 16777216
  [ "$status" -eq 0 ]
  run python3 "${script}" 10m 16777216 610s 16777216
  [ "$status" -eq 0 ]
  run python3 "${script}" 610s 16777216 610s 16777216
  [ "$status" -ne 0 ]
  [[ "$output" == *"610"* ]]
  run python3 "${script}" 11m 16777216 610s 16777216
  [ "$status" -ne 0 ]
  run python3 "${script}" 600s 1048576 610s 16777216
  [ "$status" -ne 0 ]
  [[ "$output" == *"16777216"* ]]
}

@test "health wait fails fast on deterministic 4xx and reports the body" {
  script="${REPO_ROOT}/ansible/roles/e2b_services/files/e2b-wait-health.sh"
  stub="${BATS_TMPDIR}/health-bin"
  mkdir -p "${stub}"
  cat >"${stub}/curl" <<'EOF'
#!/usr/bin/env bash
outfile=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then
    outfile="$2"
    shift 2
    continue
  fi
  shift
done
printf 'broken router' >"${outfile}"
printf '404'
exit 0
EOF
  chmod +x "${stub}/curl"
  export PATH="${stub}:${PATH}"
  run bash "${script}" http://127.0.0.1:9/health 5 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"404"* ]]
  [[ "$output" == *"broken router"* ]]
  [[ "$output" != *"timed out"* ]]
}

@test "health wait retries HTTP 503 and connection failures only" {
  script="${REPO_ROOT}/ansible/roles/e2b_services/files/e2b-wait-health.sh"
  stub="${BATS_TMPDIR}/health-bin-503"
  mkdir -p "${stub}"
  nfile="${BATS_TMPDIR}/health-n"
  echo 0 >"${nfile}"
  cat >"${stub}/curl" <<EOF
#!/usr/bin/env bash
outfile=""
while [[ \$# -gt 0 ]]; do
  if [[ "\$1" == "-o" ]]; then
    outfile="\$2"
    shift 2
    continue
  fi
  shift
done
n="\$(cat "${nfile}")"
n=\$((n + 1))
echo "\$n" >"${nfile}"
if [[ "\$n" -eq 1 ]]; then
  echo "connect fail" >&2
  exit 7
fi
if [[ "\$n" -eq 2 ]]; then
  printf 'no node' >"\${outfile}"
  printf '503'
  exit 0
fi
printf 'ok' >"\${outfile}"
printf '200'
exit 0
EOF
  chmod +x "${stub}/curl"
  export PATH="${stub}:${PATH}"
  run bash "${script}" http://127.0.0.1:8080/health 5 0
  [ "$status" -eq 0 ]
  [[ "$output" == *ready ]]
}

@test "limits helper emits only the final state token when psql prints command tags" {
  script="${REPO_ROOT}/ansible/roles/e2b_services/files/e2b-apply-limits.sh"
  stub="${BATS_TMPDIR}/psql-tags"
  cat >"${stub}" <<'EOF'
#!/usr/bin/env bash
sql="$*"
if [[ "${sql}" == *extra_concurrent_sandboxes::text* ]]; then
  echo ""
  exit 0
fi
if [[ "${sql}" == *INSERT\ INTO\ addons* ]]; then
  echo "INSERT 0 1"
  exit 0
fi
if [[ "${sql}" == *RETURNING\ 1* ]]; then
  echo ""
  exit 0
fi
exit 0
EOF
  chmod +x "${stub}"
  run bash "${script}" admin@example.com qops-concurrency 80 10 1 "${stub}"
  [ "$status" -eq 0 ]
  [ "$output" = "changed" ]
}

@test "api migration timestamp extractor needs no binutils (strings absent on Ubuntu server)" {
  extractor="${REPO_ROOT}/ansible/roles/e2b_services/files/e2b-extract-api-migration-timestamp.sh"
  work="${BATS_TMPDIR}/extract-no-strings"
  rm -rf "${work}"
  mkdir -p "${work}/bin"
  # Ubuntu 24.04 server/cloud images do not ship binutils; emulate that by
  # shadowing `strings` with a command-not-found stand-in.
  printf '#!/usr/bin/env bash\necho "strings: command not found" >&2\nexit 127\n' >"${work}/bin/strings"
  chmod 755 "${work}/bin/strings"
  python3 - "${work}/api" <<'PY'
import sys
# Go string table: the 14-digit ldflag value sits between non-printables, and a
# longer digit run nearby must not be mistaken for it.
blob = b"\x7fELF\x00\x00main.expectedMigrationTimestamp\x00" + b"20240101120000" + b"\x00" \
    + b"version=1.2.3\x00" + b"123456789012345678901234\x00" + b"\x01\x02"
open(sys.argv[1], "wb").write(blob)
PY
  run env PATH="${work}/bin:${PATH}" bash "${extractor}" "${work}/api"
  echo "${output}"
  [ "$status" -eq 0 ]
  [ "$output" = "20240101120000" ]
}

@test "orchestrator unit survives a docker restart and can finish a sandbox drain" {
  out="${BATS_TMPDIR}/e2b-orchestrator-deps.service"
  render_with_defaults ansible/roles/e2b_services/templates/e2b-orchestrator.service.j2 \
    '{"e2b_services_node_id":"node-fixture"}' >"${out}"
  # Requires= propagates a docker restart (handler, docker-ce upgrade) into the
  # orchestrator while sandboxes are live; Docker is only needed for template builds.
  ! grep -q '^Requires=docker.service' "${out}"
  grep -q '^Wants=.*docker.service' "${out}"
  # hugepage allocation must have happened, not just the mount
  grep -q '^After=.*e2b-hugepages.service' "${out}"
  # An ordinary stop drains live sandboxes (upstream ceiling ~35 min) unless the
  # force-stop marker is present; the stop timeout must not SIGKILL that drain.
  timeout="$(sed -n 's/^TimeoutStopSec=\([0-9]*\)$/\1/p' "${out}")"
  [ -n "${timeout}" ]
  [ "${timeout}" -ge 2100 ]
}

# --- hairpin probe: extra_hosts, CA, remedy, non-required degrade -------------

write_hairpin_stub() {
  # $1 = stub path, $2 = argv log; probe always fails with a connect error
  cat >"$1" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "network" && "\$2" == "inspect" ]]; then
  exit 0
fi
printf '%s\n' "\$*" >>"$2"
echo "wget: unable to connect to remote host: Connection timed out" >&2
exit 4
EOF
  chmod +x "$1"
}

@test "hairpin check in non-required mode degrades to skipped when the probe fails" {
  script="${REPO_ROOT}/ansible/roles/traefik/files/hairpin-check.sh"
  stub="${BATS_TMPDIR}/docker-hairpin-degrade"
  write_hairpin_stub "${stub}" "${BATS_TMPDIR}/hairpin-degrade.log"
  run env TRAEFIK_HAIRPIN_REQUIRED=0 TRAEFIK_HAIRPIN_RETRIES=1 TRAEFIK_HAIRPIN_DELAY=0 \
    bash "${script}" kodus "https://api.e2b.example.com/health" "img" "${stub}"
  echo "${output}"
  [ "$status" -eq 0 ]
  [[ "$output" == *skipped ]]
  [[ "$output" == *"site.yml"* ]]
}

@test "hairpin required failure names the hairpin remedy" {
  script="${REPO_ROOT}/ansible/roles/traefik/files/hairpin-check.sh"
  stub="${BATS_TMPDIR}/docker-hairpin-remedy"
  write_hairpin_stub "${stub}" "${BATS_TMPDIR}/hairpin-remedy.log"
  run env TRAEFIK_HAIRPIN_REQUIRED=1 TRAEFIK_HAIRPIN_RETRIES=1 TRAEFIK_HAIRPIN_DELAY=0 \
    bash "${script}" kodus "https://api.e2b.example.com/health" "img" "${stub}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"kodus_extra_hosts_hairpin"* ]]
  [[ "$output" == *"E2B_API_URL"* ]]
  [[ "$output" == *"E2B_SANDBOX_URL"* ]]
  # when extra hosts were already in play, say that hairpin is not the cause
  run env TRAEFIK_HAIRPIN_REQUIRED=1 TRAEFIK_HAIRPIN_RETRIES=1 TRAEFIK_HAIRPIN_DELAY=0 \
    TRAEFIK_HAIRPIN_EXTRA_HOSTS="api.e2b.example.com:host-gateway" \
    bash "${script}" kodus "https://api.e2b.example.com/health" "img" "${stub}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already"* ]]
  [[ "$output" == *"host-gateway"* ]]
}

@test "hairpin probe passes extra hosts and a CA file into the probe container" {
  script="${REPO_ROOT}/ansible/roles/traefik/files/hairpin-check.sh"
  stub="${BATS_TMPDIR}/docker-hairpin-args"
  log="${BATS_TMPDIR}/hairpin-args.log"
  : >"${log}"
  write_hairpin_stub "${stub}" "${log}"
  ca="${BATS_TMPDIR}/qops-ca.pem"
  printf 'CA\n' >"${ca}"
  run env TRAEFIK_HAIRPIN_REQUIRED=1 TRAEFIK_HAIRPIN_RETRIES=1 TRAEFIK_HAIRPIN_DELAY=0 \
    TRAEFIK_HAIRPIN_EXTRA_HOSTS="api.e2b.example.com:host-gateway kodus-api.example.com:host-gateway" \
    TRAEFIK_HAIRPIN_CA_FILE="${ca}" \
    bash "${script}" kodus "https://api.e2b.example.com/health" "img" "${stub}"
  [ "$status" -ne 0 ]
  argv="$(cat "${log}")"
  echo "${argv}"
  [[ "${argv}" == *"--add-host api.e2b.example.com:host-gateway"* ]]
  [[ "${argv}" == *"--add-host kodus-api.example.com:host-gateway"* ]]
  [[ "${argv}" == *"-v ${ca}:/qops-hairpin-ca.pem:ro"* ]]
  [[ "${argv}" == *"--ca-certificate=/qops-hairpin-ca.pem"* ]]
  # no CA and no extra hosts -> neither flag appears
  : >"${log}"
  run env TRAEFIK_HAIRPIN_REQUIRED=1 TRAEFIK_HAIRPIN_RETRIES=1 TRAEFIK_HAIRPIN_DELAY=0 \
    bash "${script}" kodus "https://api.e2b.example.com/health" "img" "${stub}"
  argv="$(cat "${log}")"
  [[ "${argv}" != *"--add-host"* ]]
  [[ "${argv}" != *"--ca-certificate"* ]]
}

@test "hairpin task hands kodus_hairpin_hosts and the CA to the probe when hairpin fallback is on" {
  run python3 - "${REPO_ROOT}" <<'PY'
import pathlib, sys, yaml
root = pathlib.Path(sys.argv[1])
tasks = yaml.safe_load((root / "ansible/roles/traefik/tasks/hairpin.yml").read_text())
probe = next(t for t in tasks if "hairpin-check.sh" in str(t.get("ansible.builtin.command", {}).get("cmd", "")))
env = probe["environment"]
hosts = str(env.get("TRAEFIK_HAIRPIN_EXTRA_HOSTS", ""))
assert "kodus_extra_hosts_hairpin" in hosts, env
assert "kodus_hairpin_hosts" in hosts, env
assert "host-gateway" in hosts, env
ca = str(env.get("TRAEFIK_HAIRPIN_CA_FILE", ""))
assert "tls_ca_path" in ca, env
gv = yaml.safe_load((root / "ansible/group_vars/all.yml").read_text())
assert "kodus_hairpin_hosts" in gv, "kodus_hairpin_hosts must be documented in group_vars"
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

# --- e2b_templates: controller -> host transfer without node_modules -----------

make_template_src() {
  local src="$1"
  rm -rf "${src}"
  mkdir -p "${src}/node_modules/e2b/dist" "${src}/.vite" "${src}/templates"
  printf '{"name":"t"}\n' >"${src}/package.json"
  printf 'export {}\n' >"${src}/build-templates.ts"
  printf 'FROM scratch\n' >"${src}/templates/Dockerfile"
  head -c 65536 /dev/zero >"${src}/node_modules/e2b/dist/index.mjs"
  printf 'cache\n' >"${src}/.vite/x"
}

@test "pack-template-sources produces a deterministic tarball without node_modules" {
  pack="${REPO_ROOT}/ansible/roles/e2b_templates/files/pack-template-sources.sh"
  src="${BATS_TMPDIR}/tpl-src"
  make_template_src "${src}"
  run bash "${pack}" "${src}" "${BATS_TMPDIR}/tpl-a.tar.gz"
  echo "${output}"
  [ "$status" -eq 0 ]
  listing="$(tar -tzf "${BATS_TMPDIR}/tpl-a.tar.gz")"
  [[ "${listing}" == *"package.json"* ]]
  [[ "${listing}" == *"templates/Dockerfile"* ]]
  [[ "${listing}" != *"node_modules"* ]]
  [[ "${listing}" != *".vite"* ]]
  [ "$(wc -c <"${BATS_TMPDIR}/tpl-a.tar.gz" | tr -d ' ')" -lt 4096 ]
  # byte-identical on repack so ansible.builtin.copy stays changed=0
  sleep 1
  touch "${src}/package.json"
  bash "${pack}" "${src}" "${BATS_TMPDIR}/tpl-b.tar.gz" >/dev/null
  cmp "${BATS_TMPDIR}/tpl-a.tar.gz" "${BATS_TMPDIR}/tpl-b.tar.gz"
}

@test "install-template-sources accepts the packed tarball and stays idempotent" {
  pack="${REPO_ROOT}/ansible/roles/e2b_templates/files/pack-template-sources.sh"
  install="${REPO_ROOT}/ansible/roles/e2b_templates/files/install-template-sources.sh"
  src="${BATS_TMPDIR}/tpl-src2"
  make_template_src "${src}"
  bash "${pack}" "${src}" "${BATS_TMPDIR}/tpl.tar.gz" >/dev/null
  dest="${BATS_TMPDIR}/tpl-install"
  rm -rf "${dest}"
  run bash "${install}" "${BATS_TMPDIR}/tpl.tar.gz" "${dest}"
  echo "${output}"
  [ "$status" -eq 0 ]
  [ "$output" = "installed" ]
  [ -f "${dest}/package.json" ]
  [ -f "${dest}/templates/Dockerfile" ]
  [ ! -e "${dest}/node_modules" ]
  run bash "${install}" "${BATS_TMPDIR}/tpl.tar.gz" "${dest}"
  [ "$status" -eq 0 ]
  [ "$output" = "unchanged" ]
}

@test "e2b_templates ships a packed tarball instead of copying the source tree" {
  run python3 - "${REPO_ROOT}/ansible/roles/e2b_templates/tasks/main.yml" <<'PY'
import sys, yaml
tasks = yaml.safe_load(open(sys.argv[1]))
for t in tasks:
    src = str(t.get("ansible.builtin.copy", {}).get("src", ""))
    assert not (src.rstrip("/").endswith("e2b_templates_controller_src_dir }}") ), "directory copy ships node_modules: " + t["name"]
pack = [t for t in tasks if "pack-template-sources.sh" in str((t.get("ansible.builtin.script") or t.get("ansible.builtin.command") or {}).get("cmd", ""))]
assert pack, "no controller-side pack step"
assert pack[0].get("delegate_to") == "localhost", "pack must run on the controller"
assert pack[0].get("become") is False
ship = [t for t in tasks if "e2b_templates_src_tarball" in str(t.get("ansible.builtin.copy", {}).get("dest", ""))
        and "e2b_templates_pack_tmp" in str(t["ansible.builtin.copy"].get("src", ""))]
assert ship, "packed tarball is never copied to the host"
install = [t for t in tasks if "install-template-sources.sh" in str(t.get("ansible.builtin.command", {}).get("cmd", ""))]
assert install and "e2b_templates_src_tarball" in install[0]["ansible.builtin.command"]["cmd"], "installer must consume the tarball"
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "e2b_datastores compose task detects changes on stderr where compose reports them" {
  run python3 - "${REPO_ROOT}/ansible/roles/e2b_datastores/tasks/main.yml" <<'PY'
import sys, yaml
tasks = yaml.safe_load(open(sys.argv[1]))
up = next(t for t in tasks if "up -d" in str(t.get("ansible.builtin.command", {}).get("cmd", "")))
cw = str(up.get("changed_when", ""))
# `docker compose up` prints Created/Started/Recreated progress on stderr.
assert "stderr" in cw, cw
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "provided TLS check verifies the certificate covers every routed hostname" {
  script="${REPO_ROOT}/ansible/roles/traefik/files/check-provided-tls.sh"
  work="${BATS_TMPDIR}/tls-san"
  rm -rf "${work}"; mkdir -p "${work}"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=example.com' \
    -addext 'subjectAltName=DNS:example.com,DNS:*.example.com' \
    -keyout "${work}/tls.key" -out "${work}/tls.crt" >/dev/null 2>&1
  # one-level wildcard covers kodus.example.com but not *.e2b.example.com
  run bash "${script}" "${work}/tls.crt" "${work}/tls.key" "" "kodus.example.com,kodus-api.example.com"
  [ "$status" -eq 0 ]
  run bash "${script}" "${work}/tls.crt" "${work}/tls.key" "" "kodus.example.com,api.e2b.example.com,x.e2b.example.com"
  echo "${output}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"api.e2b.example.com"* ]]
  [[ "$output" == *"x.e2b.example.com"* ]]
  [[ "$output" != *"kodus.example.com"* ]]
  run python3 - "${REPO_ROOT}/ansible/roles/traefik/tasks/main.yml" <<'PY'
import sys, yaml
tasks = yaml.safe_load(open(sys.argv[1]))
t = next(t for t in tasks if "check-provided-tls.sh" in str(t.get("ansible.builtin.command", {}).get("cmd", "")))
cmd = t["ansible.builtin.command"]["cmd"]
assert "traefik_provided_tls_hostnames" in cmd, cmd
import pathlib
defaults = yaml.safe_load(pathlib.Path(sys.argv[1]).parent.parent.joinpath("defaults/main.yml").read_text())
names = " ".join(defaults["traefik_provided_tls_hostnames"])
for name in ("api.e2b.", "kodus.", "kodus-api.", "kodus-webhooks.", ".e2b."):
    assert name in names, f"{name} missing from traefik_provided_tls_hostnames: {names}"
assert any(n.endswith("e2b.{{ qops_domain }}") and not n.startswith("api.") for n in defaults["traefik_provided_tls_hostnames"]), "no *.e2b sample label"
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "e2b-set-secret takes the value on stdin so it never appears in process listings" {
  script="${REPO_ROOT}/ansible/roles/e2b_services/files/e2b-set-secret.sh"
  f="${BATS_TMPDIR}/set-secret.env"
  printf 'A=1\nE2B_API_KEY=\n' >"${f}"
  run bash -c 'printf "%s" "$1" | bash "$2" "$3" E2B_API_KEY' _ 'e2b_fromstdin' "${script}" "${f}"
  echo "${output}"
  [ "$status" -eq 0 ]
  grep -q '^E2B_API_KEY=e2b_fromstdin$' "${f}"
  grep -q '^A=1$' "${f}"
  # an argv value is refused, not silently accepted
  run bash "${script}" "${f}" E2B_API_KEY e2b_onargv
  [ "$status" -ne 0 ]
  [[ "$output" == *"stdin"* ]]
  ! grep -q 'e2b_onargv' "${f}"
  seed="${REPO_ROOT}/ansible/roles/e2b_services/files/e2b-seed-if-needed.sh"
  ! grep -Eq 'e2b-set-secret\.sh" "\$\{SECRETS_FILE\}" E2B_API_KEY "\$\{key\}"' "${seed}"
}

@test "controller-delegated template tasks pin ansible_become=false against inventory become" {
  run python3 - "${REPO_ROOT}/ansible/roles/e2b_templates/tasks/main.yml" <<'PY'
import sys, yaml
tasks = yaml.safe_load(open(sys.argv[1]))
delegated = [t for t in tasks if t.get("delegate_to") == "localhost"]
assert len(delegated) >= 3, [t["name"] for t in delegated]
for t in delegated:
    # Inventory ansible_become (ci/matrix/inventory-localhost.yml, or all: vars:)
    # overrides the task keyword become: false; task vars outrank inventory.
    assert t.get("vars", {}).get("ansible_become") is False, t["name"]
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "ACME installer can validate key names without values so the failure is readable" {
  script="${REPO_ROOT}/ansible/roles/traefik/files/install-traefik-acme-env.sh"
  run bash "${script}" --check-keys porkbun "" "PORKBUN_API_KEY,PORKBUN_SECRET_KEY"
  echo "${output}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"PORKBUN_SECRET_KEY"* ]]
  [[ "$output" == *"PORKBUN_SECRET_API_KEY"* ]]
  run bash "${script}" --check-keys porkbun "" "PORKBUN_API_KEY,PORKBUN_SECRET_API_KEY"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
  run bash "${script}" --check-keys exoticdns "MY_TOKEN" "MY_TOKEN"
  [ "$status" -eq 0 ]
  run python3 - "${REPO_ROOT}/ansible/roles/traefik/tasks/main.yml" <<'PY'
import sys, yaml
tasks = yaml.safe_load(open(sys.argv[1]))
install = next(i for i, t in enumerate(tasks)
               if "install-traefik-acme-env.sh" in str(t.get("ansible.builtin.command", {}).get("cmd", ""))
               and "--check-keys" not in str(t["ansible.builtin.command"]["cmd"]))
check = [i for i, t in enumerate(tasks[:install])
         if "--check-keys" in str(t.get("ansible.builtin.command", {}).get("cmd", ""))]
assert check, "no readable key-name validation before the no_log install"
t = tasks[check[0]]
assert t.get("no_log") is not True, "key-name check must be visible"
assert "keys()" in t["ansible.builtin.command"]["cmd"] or "| list" in t["ansible.builtin.command"]["cmd"], t["ansible.builtin.command"]["cmd"]
asserts = [t for t in tasks[:install] if "ansible.builtin.assert" in t and "tls_acme_dns_credentials" in str(t["ansible.builtin.assert"])]
blob = str(asserts[-1]["ansible.builtin.assert"]["that"])
assert "ENC" in blob, "assert must reject undecrypted sops values (ENC[...])"
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}
