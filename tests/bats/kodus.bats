#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export ANSIBLE_CONFIG="${REPO_ROOT}/ansible.cfg"
  export ANSIBLE_ROLES_PATH="${REPO_ROOT}/ansible/roles"
  FIXTURE="${REPO_ROOT}/tests/fixtures/upstream-kodus-installer"
  RENDER_PY="${REPO_ROOT}/ansible/roles/kodus/files/render-kodus-env.py"
  PERSIST_SH="${REPO_ROOT}/ansible/roles/kodus/files/persist-kodus-secrets.sh"
  INSTALL_SH="${REPO_ROOT}/ansible/roles/kodus/files/kodus-install-if-needed.sh"
  NETWORKS_SH="${REPO_ROOT}/ansible/roles/kodus/files/kodus-ensure-networks.sh"
  CALLBACKS_SH="${REPO_ROOT}/ansible/roles/kodus/files/kodus-print-callbacks.sh"
  WORKDIR="${BATS_TMPDIR}/kodus-work"
  rm -rf "${WORKDIR}"
  mkdir -p "${WORKDIR}/installer/scripts" "${WORKDIR}/persist" "${WORKDIR}/bin"
  cp "${FIXTURE}/.env.example" "${WORKDIR}/installer/.env.example"
  cp "${FIXTURE}/docker-compose.yml" "${WORKDIR}/installer/docker-compose.yml"
  cp "${FIXTURE}/scripts/"* "${WORKDIR}/installer/scripts/"
  chmod +x "${WORKDIR}/installer/scripts/"*.sh
}

write_config() {
  python3 - "${WORKDIR}/config.json" "${REPO_ROOT}" <<'PY'
import json, pathlib, sys, yaml
out, root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
versions = yaml.safe_load((root / "versions.yml").read_text())
cfg = {
    "qops_domain": "example.com",
    "web_host": "kodus.example.com",
    "api_host": "kodus-api.example.com",
    "webhooks_host": "kodus-webhooks.example.com",
    "web_url": "https://kodus.example.com",
    "e2b_domain": "e2b.example.com",
    "e2b_api_key": "e2b_" + "a" * 40,
    "image_tag": versions["kodus_image_tag"],
    "sandbox_provider": "e2b",
    "template_id": "kodus-sandbox",
    "template_graph_id": "kodus-sandbox-graph",
    "worker_role": "code-review",
    "cloud_mode": False,
    "telemetry_disabled": False,
    "license_key": "",
    "llm_provider_model": "auto",
    "openai_api_key": "sk-test",
    "openai_force_base_url": "",
    "web_port_api": "443",
    "env_overrides": {},
}
out.write_text(json.dumps(cfg))
PY
}

render_env() {
  write_config
  python3 "${RENDER_PY}" \
    --example "${WORKDIR}/installer/.env.example" \
    --output "${WORKDIR}/installer/.env" \
    --config "${WORKDIR}/config.json" \
    --overlay "${WORKDIR}/persist/generated-secrets.env" \
    --mode 0600
}

dotenv_get() {
  python3 - "$1" "$2" <<'PY'
import re, sys
assign = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
wanted = sys.argv[2]
for raw in open(sys.argv[1], encoding="utf-8"):
    match = assign.match(raw.strip())
    if match and match.group(1) == wanted:
        value = match.group(2)
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        print(value)
        raise SystemExit(0)
raise SystemExit(1)
PY
}

@test "rendered .env has required-by-installer vars, E2B block, pinned IMAGE_TAG, and valid webhooks" {
  render_env
  envf="${WORKDIR}/installer/.env"
  for key in API_PG_DB_PASSWORD API_MG_DB_PASSWORD WORKER_ROLE API_JWT_SECRET \
    API_JWT_REFRESH_SECRET API_CRYPTO_KEY CODE_MANAGEMENT_SECRET \
    WEB_NEXTAUTH_SECRET NEXTAUTH_SECRET; do
    grep -q "^${key}=" "${envf}"
  done
  [ "$(dotenv_get "${envf}" SANDBOX_PROVIDER)" = "e2b" ]
  [ "$(dotenv_get "${envf}" E2B_DOMAIN)" = "e2b.example.com" ]
  [ "$(dotenv_get "${envf}" API_E2B_TEMPLATE_ID)" = "kodus-sandbox" ]
  [ "$(dotenv_get "${envf}" API_E2B_TEMPLATE_GRAPH_ID)" = "kodus-sandbox-graph" ]
  [ "$(dotenv_get "${envf}" API_E2B_KEY)" = "e2b_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]
  [ "$(dotenv_get "${envf}" API_RABBITMQ_ENABLED)" = "true" ]
  [ "$(dotenv_get "${envf}" API_CLOUD_MODE)" = "false" ]
  [ "$(dotenv_get "${envf}" WORKER_ROLE)" = "code-review" ]
  [ "$(dotenv_get "${envf}" WEB_HOSTNAME_API)" = "kodus-api.example.com" ]
  [ "$(dotenv_get "${envf}" NEXTAUTH_URL)" = "https://kodus.example.com" ]
  [ "$(dotenv_get "${envf}" API_FRONTEND_URL)" = "https://kodus.example.com" ]
  [ "$(dotenv_get "${envf}" API_USER_INVITE_BASE_URL)" = "https://kodus.example.com" ]
  [ "$(dotenv_get "${envf}" API_MCP_MANAGER_REDIRECT_URI)" = "https://kodus.example.com/setup/mcp/oauth" ]
  [ "$(dotenv_get "${envf}" API_KODUS_MCP_SERVER_URL)" = "https://kodus-api.example.com/mcp" ]
  [ "$(dotenv_get "${envf}" API_GITHUB_CODE_MANAGEMENT_WEBHOOK)" = "https://kodus-webhooks.example.com/github/webhook" ]
  [ "$(dotenv_get "${envf}" API_GITLAB_CODE_MANAGEMENT_WEBHOOK)" = "https://kodus-webhooks.example.com/gitlab/webhook" ]
  [ "$(dotenv_get "${envf}" GLOBAL_BITBUCKET_CODE_MANAGEMENT_WEBHOOK)" = "https://kodus-webhooks.example.com/bitbucket/webhook" ]
  [ "$(dotenv_get "${envf}" GLOBAL_AZURE_REPOS_CODE_MANAGEMENT_WEBHOOK)" = "https://kodus-webhooks.example.com/azure-repos/webhook" ]
  [ "$(dotenv_get "${envf}" API_FORGEJO_CODE_MANAGEMENT_WEBHOOK)" = "https://kodus-webhooks.example.com/forgejo/webhook" ]
  [ "$(dotenv_get "${envf}" API_LLM_PROVIDER_MODEL)" = "auto" ]
  [ "$(dotenv_get "${envf}" API_OPEN_AI_API_KEY)" = "sk-test" ]
  tag="$(dotenv_get "${envf}" IMAGE_TAG)"
  [ "${tag}" != "latest" ]
  [ -n "${tag}" ]
  ! grep -q '^E2B_PROXY_HOST=' "${envf}"
  [ "$(stat -c '%a' "${envf}")" = "600" ]
}

@test "renderer refuses IMAGE_TAG=latest" {
  write_config
  python3 - "${WORKDIR}/config.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
cfg = json.loads(path.read_text())
cfg["image_tag"] = "latest"
path.write_text(json.dumps(cfg))
PY
  run python3 "${RENDER_PY}" \
    --example "${WORKDIR}/installer/.env.example" \
    --output "${WORKDIR}/installer/.env" \
    --config "${WORKDIR}/config.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"latest"* ]]
}

@test "generate-secrets.sh runs only once and a re-run reuses persisted values" {
  render_env
  marker="${WORKDIR}/secret-runs.log"
  run env KODUS_SECRETS_MARKER="${marker}" bash "${PERSIST_SH}" \
    "${WORKDIR}/installer/.env" \
    "${WORKDIR}/persist/generated-secrets.env" \
    "${WORKDIR}/installer/scripts/generate-secrets.sh" \
    "${WORKDIR}/installer/scripts/schema-vars.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"generated"* ]]
  [ -f "${WORKDIR}/persist/generated-secrets.env" ]
  jwt1="$(dotenv_get "${WORKDIR}/installer/.env" API_JWT_SECRET)"
  pg1="$(dotenv_get "${WORKDIR}/installer/.env" API_PG_DB_PASSWORD)"
  [ -n "${jwt1}" ]
  [ -n "${pg1}" ]
  run env KODUS_SECRETS_MARKER="${marker}" bash "${PERSIST_SH}" \
    "${WORKDIR}/installer/.env" \
    "${WORKDIR}/persist/generated-secrets.env" \
    "${WORKDIR}/installer/scripts/generate-secrets.sh" \
    "${WORKDIR}/installer/scripts/schema-vars.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reused"* ]]
  jwt2="$(dotenv_get "${WORKDIR}/installer/.env" API_JWT_SECRET)"
  pg2="$(dotenv_get "${WORKDIR}/installer/.env" API_PG_DB_PASSWORD)"
  [ "${jwt1}" = "${jwt2}" ]
  [ "${pg1}" = "${pg2}" ]
  [ "$(grep -c '^generated$' "${marker}")" -eq 1 ]
  [ "$(grep -c '^reused$' "${marker}")" -eq 1 ]
}

@test "upstream install.sh and validate-env.sh accept the rendered .env with docker stubbed" {
  render_env
  env KODUS_SECRETS_MARKER="${WORKDIR}/secret-runs.log" bash "${PERSIST_SH}" \
    "${WORKDIR}/installer/.env" \
    "${WORKDIR}/persist/generated-secrets.env" \
    "${WORKDIR}/installer/scripts/generate-secrets.sh" \
    "${WORKDIR}/installer/scripts/schema-vars.sh"
  cat >"${WORKDIR}/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
case "$args" in
  compose\ version*) echo "Docker Compose version v2.29.0"; exit 0 ;;
  network*) exit 0 ;;
  compose\ up*) echo "UP $args"; exit 0 ;;
  compose\ ps*) echo "cid-stub"; exit 0 ;;
  inspect*) echo healthy; exit 0 ;;
  compose\ exec*) exit 0 ;;
  compose\ logs*) echo "Ready in 12ms"; exit 0 ;;
  compose\ config*) echo "ok"; exit 0 ;;
  info*) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "${WORKDIR}/bin/docker"
  run env PATH="${WORKDIR}/bin:${PATH}" bash -c \
    "cd '${WORKDIR}/installer' && bash scripts/validate-env.sh"
  echo "validate-env: $output"
  [ "$status" -eq 0 ]
  run env PATH="${WORKDIR}/bin:${PATH}" bash -c \
    "cd '${WORKDIR}/installer' && bash scripts/install.sh"
  echo "install.sh: $output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Error: invalid environment variables"* ]]
  [[ "$output" != *"Missing required environment variables"* ]]
  [[ "$output" == *"Starting containers"* ]]
}

@test "install.sh invocation is gated so a healthy stack is not force-recreated" {
  render_env
  cat >"${WORKDIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo -n 200
EOF
  chmod +x "${WORKDIR}/bin/curl"
  cat >"${WORKDIR}/installer/scripts/install.sh" <<'EOF'
#!/usr/bin/env bash
echo FORCE-RECREATE
exit 0
EOF
  run env PATH="${WORKDIR}/bin:${PATH}" KODUS_CURL_BIN="${WORKDIR}/bin/curl" \
    bash "${INSTALL_SH}" "${WORKDIR}/installer" \
    http://127.0.0.1:3000/health http://127.0.0.1:3001/health
  [ "$status" -eq 0 ]
  [ "$output" = "skipped-healthy" ]
  [[ "$output" != *"FORCE-RECREATE"* ]]

  cat >"${WORKDIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo -n 000
exit 1
EOF
  run env PATH="${WORKDIR}/bin:${PATH}" KODUS_CURL_BIN="${WORKDIR}/bin/curl" \
    bash "${INSTALL_SH}" "${WORKDIR}/installer" \
    http://127.0.0.1:3000/health
  [ "$status" -eq 0 ]
  [[ "$output" == *"FORCE-RECREATE"* ]]
  [[ "$output" == *"installed"* ]]
}

@test "compose override rebinds every upstream published port to 127.0.0.1" {
  run python3 - "${REPO_ROOT}" "${BATS_TMPDIR}" "${WORKDIR}/installer/docker-compose.yml" <<'PY'
import json
import pathlib
import subprocess
import sys
import yaml

root = pathlib.Path(sys.argv[1])
tmpdir = pathlib.Path(sys.argv[2])
upstream = yaml.safe_load(pathlib.Path(sys.argv[3]).read_text())
merged = {}
for path in (root / "versions.yml", root / "ansible/group_vars/all.yml"):
    merged.update(yaml.safe_load(path.read_text()) or {})
for role in (
    "preflight", "common", "host_firewall", "docker", "e2b_host",
    "e2b_datastores", "e2b_services", "e2b_templates", "traefik", "kodus", "doctor",
):
    defaults = root / f"ansible/roles/{role}/defaults/main.yml"
    if defaults.is_file():
        merged.update(yaml.safe_load(defaults.read_text()) or {})
vars_file = tmpdir / "kodus-vars.yml"
vars_file.write_text(yaml.safe_dump(merged))
override_text = subprocess.check_output(
    ["bash", str(root / "tests/fixtures/render-template.sh"),
     "ansible/roles/kodus/templates/docker-compose.override.yml.j2", str(vars_file)],
    text=True, cwd=root,
)
override = yaml.safe_load(override_text)
assert override, override_text
up_ports = {}
for name, svc in (upstream.get("services") or {}).items():
    ports = svc.get("ports") or []
    if ports:
        up_ports[name] = ports
ov_services = override.get("services") or {}
missing = sorted(set(up_ports) - set(ov_services))
assert not missing, f"override missing services with published ports: {missing}"
for name, ports in up_ports.items():
    ov_ports = ov_services[name].get("ports") or []
    assert len(ov_ports) >= len(ports), (name, ports, ov_ports)
    for mapping in ov_ports:
        assert str(mapping).startswith("127.0.0.1:"), (name, mapping)
        assert "0.0.0.0" not in str(mapping)
assert "0.0.0.0" not in override_text
postgres = ov_services["db_kodus_postgres"]
assert postgres.get("restart") == "unless-stopped"
mongo = ov_services["db_kodus_mongodb"]
assert mongo.get("restart") == "unless-stopped"
vol = " ".join(str(v) for v in postgres.get("volumes") or [])
assert ":z" in vol
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "compose override port test fails if a newly published upstream port is omitted" {
  python3 - "${WORKDIR}/installer/docker-compose.yml" <<'PY'
import yaml, sys
path = sys.argv[1]
doc = yaml.safe_load(open(path))
doc["services"]["api"]["ports"].append("3999:3999")
yaml.safe_dump(doc, open(path, "w"))
PY
  run python3 - "${REPO_ROOT}" "${BATS_TMPDIR}" "${WORKDIR}/installer/docker-compose.yml" <<'PY'
import pathlib, subprocess, sys, yaml
root = pathlib.Path(sys.argv[1])
tmpdir = pathlib.Path(sys.argv[2])
upstream = yaml.safe_load(pathlib.Path(sys.argv[3]).read_text())
merged = {}
for path in (root / "versions.yml", root / "ansible/group_vars/all.yml"):
    merged.update(yaml.safe_load(path.read_text()) or {})
for role in (
    "preflight", "common", "host_firewall", "docker", "e2b_host",
    "e2b_datastores", "e2b_services", "e2b_templates", "traefik", "kodus", "doctor",
):
    defaults = root / f"ansible/roles/{role}/defaults/main.yml"
    if defaults.is_file():
        merged.update(yaml.safe_load(defaults.read_text()) or {})
vars_file = tmpdir / "kodus-vars2.yml"
vars_file.write_text(yaml.safe_dump(merged))
override_text = subprocess.check_output(
    ["bash", str(root / "tests/fixtures/render-template.sh"),
     "ansible/roles/kodus/templates/docker-compose.override.yml.j2", str(vars_file)],
    text=True, cwd=root,
)
override = yaml.safe_load(override_text)
up = upstream["services"]["api"]["ports"]
ov = override["services"]["api"]["ports"]
if len(ov) < len(up):
    print("caught missing port")
    raise SystemExit(0)
print("did not catch extra upstream port")
raise SystemExit(1)
PY
  [ "$status" -eq 0 ]
  [ "$output" = "caught missing port" ]
}

@test "callback URL helper prints GitHub App and OAuth URLs" {
  run bash "${CALLBACKS_SH}" https://kodus.example.com https://kodus-webhooks.example.com \
    https://kodus-api.example.com "${WORKDIR}/callbacks.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://kodus.example.com/api/auth/callback/github"* ]]
  [[ "$output" == *"https://kodus.example.com/setup/github"* ]]
  [[ "$output" == *"https://kodus-webhooks.example.com/github/webhook"* ]]
  [[ "$output" == *"https://kodus.example.com/setup/mcp/oauth"* ]]
  grep -q 'api/auth/callback/github' "${WORKDIR}/callbacks.txt"
}

@test "network helper is idempotent with a docker stub" {
  cat >"${WORKDIR}/bin/docker" <<'EOF'
#!/usr/bin/env bash
log="${DOCKER_STUB_LOG:?}"
printf '%s\n' "$*" >>"${log}"
if [[ "$1" == "network" && "$2" == "inspect" ]]; then
  if grep -q "network create ${3}" "${log}"; then
    exit 0
  fi
  exit 1
fi
if [[ "$1" == "network" && "$2" == "create" ]]; then
  exit 0
fi
exit 0
EOF
  chmod +x "${WORKDIR}/bin/docker"
  : >"${WORKDIR}/docker.log"
  run env PATH="${WORKDIR}/bin:${PATH}" DOCKER_STUB_LOG="${WORKDIR}/docker.log" DOCKER_BIN=docker \
    bash "${NETWORKS_SH}" shared-network kodus
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed"* ]]
  run env PATH="${WORKDIR}/bin:${PATH}" DOCKER_STUB_LOG="${WORKDIR}/docker.log" DOCKER_BIN=docker \
    bash "${NETWORKS_SH}" shared-network kodus
  [ "$status" -eq 0 ]
  [[ "$output" == *"unchanged"* ]]
}

@test "install.sh webhook host matching is not enforced (upstream discrepancy)" {
  render_env
  env KODUS_SECRETS_MARKER="${WORKDIR}/secret-runs.log" bash "${PERSIST_SH}" \
    "${WORKDIR}/installer/.env" \
    "${WORKDIR}/persist/generated-secrets.env" \
    "${WORKDIR}/installer/scripts/generate-secrets.sh" \
    "${WORKDIR}/installer/scripts/schema-vars.sh"
  cat >"${WORKDIR}/bin/docker" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  compose\ version*) echo v2; exit 0 ;;
  compose\ up*) echo UP; exit 0 ;;
  compose\ ps*) echo cid; exit 0 ;;
  inspect*) echo healthy; exit 0 ;;
  compose\ exec*) exit 0 ;;
  compose\ logs*) echo "Ready in 1ms"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "${WORKDIR}/bin/docker"
  run env PATH="${WORKDIR}/bin:${PATH}" bash -c \
    "cd '${WORKDIR}/installer' && bash scripts/install.sh"
  [ "$status" -eq 0 ]
  host_api="$(dotenv_get "${WORKDIR}/installer/.env" WEB_HOSTNAME_API)"
  hook="$(dotenv_get "${WORKDIR}/installer/.env" API_GITHUB_CODE_MANAGEMENT_WEBHOOK)"
  [[ "${host_api}" == "kodus-api.example.com" ]]
  [[ "${hook}" == https://kodus-webhooks.example.com/* ]]
  [[ "${hook}" != *"${host_api}"* ]]
}
