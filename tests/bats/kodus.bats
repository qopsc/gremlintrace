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
  MERGE_PY="${REPO_ROOT}/ansible/roles/kodus/files/compose-merge-ports.py"
  VALIDATE_PY="${REPO_ROOT}/ansible/roles/kodus/files/validate-kodus-webhooks.py"
  INTERPRET_PY="${REPO_ROOT}/ansible/roles/kodus/files/interpret-kodus-doctor.py"
  RUN_DOCTOR_SH="${REPO_ROOT}/ansible/roles/kodus/files/kodus-run-doctor.sh"
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
    "hairpin_fallback": True,
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
  [ "$(dotenv_get "${envf}" E2B_API_URL)" = "https://api.e2b.example.com" ]
  [ "$(dotenv_get "${envf}" E2B_SANDBOX_URL)" = "https://sandbox.e2b.example.com" ]
  tag="$(dotenv_get "${envf}" IMAGE_TAG)"
  [ "${tag}" != "latest" ]
  [ -n "${tag}" ]
  ! grep -q '^E2B_PROXY_HOST=' "${envf}"
  if stat -c '%a' "${envf}" >/dev/null 2>&1; then
    mode="$(stat -c '%a' "${envf}")"
  else
    mode="$(stat -f '%Lp' "${envf}")"
  fi
  [ "${mode}" = "600" ]
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

@test "install.sh is gated on desired-state digest and container existence" {
  render_env
  bash "${REPO_ROOT}/tests/fixtures/render-template.sh" \
    ansible/roles/kodus/templates/docker-compose.override.yml.j2 \
    >"${WORKDIR}/installer/docker-compose.override.yml" || true
  python3 - "${REPO_ROOT}" "${WORKDIR}" <<'PY'
import pathlib, subprocess, sys, yaml, tempfile
root = pathlib.Path(sys.argv[1])
workdir = pathlib.Path(sys.argv[2])
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
vars_file = workdir / "kodus-vars.yml"
vars_file.write_text(yaml.safe_dump(merged))
text = subprocess.check_output(
    ["bash", str(root / "tests/fixtures/render-template.sh"),
     "ansible/roles/kodus/templates/docker-compose.override.yml.j2", str(vars_file)],
    text=True, cwd=root,
)
(workdir / "installer" / "docker-compose.override.yml").write_text(text)
PY
  cat >"${WORKDIR}/installer/scripts/install.sh" <<'EOF'
#!/usr/bin/env bash
echo FORCE-RECREATE
exit 0
EOF
  chmod +x "${WORKDIR}/installer/scripts/install.sh"
  digest="$(python3 "${MERGE_PY}" digest --base "${WORKDIR}/installer/docker-compose.yml" \
    --override "${WORKDIR}/installer/docker-compose.override.yml" \
    --env-file "${WORKDIR}/installer/.env" --ref testdigest)"
  printf '%s\n' "${digest}" >"${WORKDIR}/persist/install.digest"
  cat >"${WORKDIR}/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *ps* ]]; then
  echo cid-running
  exit 0
fi
exit 0
EOF
  chmod +x "${WORKDIR}/bin/docker"
  run env PATH="${WORKDIR}/bin:${PATH}" DOCKER_BIN=docker \
    KODUS_COMPOSE_MERGE_PY="${MERGE_PY}" \
    bash "${INSTALL_SH}" "${WORKDIR}/installer" "${WORKDIR}/persist/install.digest" testdigest
  echo "unchanged: $output"
  [ "$status" -eq 0 ]
  [ "$output" = "skipped-unchanged" ]
  [[ "$output" != *"FORCE-RECREATE"* ]]

  cat >"${WORKDIR}/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *ps* ]]; then
  exit 0
fi
exit 0
EOF
  run env PATH="${WORKDIR}/bin:${PATH}" DOCKER_BIN=docker \
    KODUS_COMPOSE_MERGE_PY="${MERGE_PY}" \
    bash "${INSTALL_SH}" "${WORKDIR}/installer" "${WORKDIR}/persist/install.digest" testdigest
  echo "missing-containers: $output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FORCE-RECREATE"* ]]
  [[ "$output" == *"installed"* ]]

  printf '%s\n' "${digest}" >"${WORKDIR}/persist/install.digest"
  cat >"${WORKDIR}/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo cid-running
exit 0
EOF
  python3 - "${WORKDIR}/installer/.env" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text().replace("IMAGE_TAG=2.1.31", "IMAGE_TAG=2.1.99", 1)
if "IMAGE_TAG=2.1.99" not in text:
    text = text.replace("IMAGE_TAG=", "IMAGE_TAG=2.1.99\nX=", 1)
path.write_text(text)
PY
  run env PATH="${WORKDIR}/bin:${PATH}" DOCKER_BIN=docker \
    KODUS_COMPOSE_MERGE_PY="${MERGE_PY}" \
    bash "${INSTALL_SH}" "${WORKDIR}/installer" "${WORKDIR}/persist/install.digest" testdigest
  echo "changed-env: $output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FORCE-RECREATE"* ]]

  cat >"${WORKDIR}/installer/scripts/install.sh" <<'EOF'
#!/usr/bin/env bash
echo INSTALL-FAILED
exit 1
EOF
  : >"${WORKDIR}/persist/install.digest"
  run env PATH="${WORKDIR}/bin:${PATH}" DOCKER_BIN=docker \
    KODUS_COMPOSE_MERGE_PY="${MERGE_PY}" \
    bash "${INSTALL_SH}" "${WORKDIR}/installer" "${WORKDIR}/persist/install.digest" testdigest
  [ "$status" -ne 0 ]
  [ ! -s "${WORKDIR}/persist/install.digest" ] || [ "$(cat "${WORKDIR}/persist/install.digest")" = "" ]
}

@test "compose desired-state digest includes CA environment and volumes" {
  render_env
  run python3 - "${REPO_ROOT}" "${WORKDIR}" "${MERGE_PY}" <<'PY'
import pathlib, subprocess, sys, yaml

root = pathlib.Path(sys.argv[1])
workdir = pathlib.Path(sys.argv[2])
merge_py = pathlib.Path(sys.argv[3])
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

digests = []
for name, tls_mode, ca_path in (("plain", "acme_dns", ""), ("ca", "internal_ca", "/etc/qops/ca.pem")):
    values = dict(merged, tls_mode=tls_mode, tls_ca_path=ca_path)
    vars_file = workdir / f"digest-{name}.yml"
    override_file = workdir / f"override-{name}.yml"
    vars_file.write_text(yaml.safe_dump(values))
    override_file.write_text(subprocess.check_output(
        ["bash", str(root / "tests/fixtures/render-template.sh"),
         "ansible/roles/kodus/templates/docker-compose.override.yml.j2", str(vars_file)],
        text=True, cwd=root,
    ))
    digest = subprocess.check_output(
        ["python3", str(merge_py), "digest",
         "--base", str(workdir / "installer/docker-compose.yml"),
         "--override", str(override_file),
         "--env-file", str(workdir / "installer/.env"), "--ref", "test"],
        text=True, cwd=root,
    ).strip()
    digests.append(digest)
assert digests[0] != digests[1], digests
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "merged compose config rebinds every upstream published port to 127.0.0.1" {
  run python3 - "${REPO_ROOT}" "${BATS_TMPDIR}" "${WORKDIR}/installer/docker-compose.yml" "${MERGE_PY}" <<'PY'
import json
import pathlib
import subprocess
import sys
import yaml

root = pathlib.Path(sys.argv[1])
tmpdir = pathlib.Path(sys.argv[2])
upstream_path = pathlib.Path(sys.argv[3])
merge_py = pathlib.Path(sys.argv[4])
merged_vars = {}
for path in (root / "versions.yml", root / "ansible/group_vars/all.yml"):
    merged_vars.update(yaml.safe_load(path.read_text()) or {})
for role in (
    "preflight", "common", "host_firewall", "docker", "e2b_host",
    "e2b_datastores", "e2b_services", "e2b_templates", "traefik", "kodus", "doctor",
):
    defaults = root / f"ansible/roles/{role}/defaults/main.yml"
    if defaults.is_file():
        merged_vars.update(yaml.safe_load(defaults.read_text()) or {})
vars_file = tmpdir / "kodus-vars.yml"
vars_file.write_text(yaml.safe_dump(merged_vars))
override_text = subprocess.check_output(
    ["bash", str(root / "tests/fixtures/render-template.sh"),
     "ansible/roles/kodus/templates/docker-compose.override.yml.j2", str(vars_file)],
    text=True, cwd=root,
)
assert "ports: !override" in override_text, override_text
override_path = tmpdir / "docker-compose.override.yml"
override_path.write_text(override_text)
report = json.loads(subprocess.check_output(
    ["python3", str(merge_py), "check", "--base", str(upstream_path),
     "--override", str(override_path), "--require-ip", "127.0.0.1"],
    text=True, cwd=root,
))
assert report["ok"] is True, report
assert report["violations"] == []
assert report["missing_upstream_targets"] == []
for item in report["ports"]:
    assert item["effective_ip"] == "127.0.0.1", item
tags = report["override_ports_tags"]
assert tags, tags
assert all(tag == "!override" for tag in tags.values()), tags
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "compose merge check fails if !override is removed" {
  run python3 - "${REPO_ROOT}" "${BATS_TMPDIR}" "${WORKDIR}/installer/docker-compose.yml" "${MERGE_PY}" <<'PY'
import json, pathlib, subprocess, sys, yaml
root = pathlib.Path(sys.argv[1])
tmpdir = pathlib.Path(sys.argv[2])
upstream_path = pathlib.Path(sys.argv[3])
merge_py = pathlib.Path(sys.argv[4])
merged_vars = {}
for path in (root / "versions.yml", root / "ansible/group_vars/all.yml"):
    merged_vars.update(yaml.safe_load(path.read_text()) or {})
for role in (
    "preflight", "common", "host_firewall", "docker", "e2b_host",
    "e2b_datastores", "e2b_services", "e2b_templates", "traefik", "kodus", "doctor",
):
    defaults = root / f"ansible/roles/{role}/defaults/main.yml"
    if defaults.is_file():
        merged_vars.update(yaml.safe_load(defaults.read_text()) or {})
vars_file = tmpdir / "kodus-vars-no-override.yml"
vars_file.write_text(yaml.safe_dump(merged_vars))
override_text = subprocess.check_output(
    ["bash", str(root / "tests/fixtures/render-template.sh"),
     "ansible/roles/kodus/templates/docker-compose.override.yml.j2", str(vars_file)],
    text=True, cwd=root,
)
stripped = override_text.replace("ports: !override", "ports:")
assert "ports: !override" not in stripped
override_path = tmpdir / "docker-compose.override.no-tag.yml"
override_path.write_text(stripped)
proc = subprocess.run(
    ["python3", str(merge_py), "check", "--base", str(upstream_path),
     "--override", str(override_path), "--require-ip", "127.0.0.1"],
    text=True, cwd=root, capture_output=True,
)
report = json.loads(proc.stdout)
assert proc.returncode != 0, report
assert report["ok"] is False
assert report["violations"], report
assert any(v["effective_ip"] != "127.0.0.1" for v in report["violations"]), report
print("caught missing !override")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "caught missing !override" ]
}

@test "compose override port test fails if a newly published upstream port is omitted" {
  python3 - "${WORKDIR}/installer/docker-compose.yml" <<'PY'
import yaml, sys
path = sys.argv[1]
doc = yaml.safe_load(open(path))
doc["services"]["api"]["ports"].append("3999:3999")
yaml.safe_dump(doc, open(path, "w"))
PY
  run python3 - "${REPO_ROOT}" "${BATS_TMPDIR}" "${WORKDIR}/installer/docker-compose.yml" "${MERGE_PY}" <<'PY'
import json, pathlib, subprocess, sys, yaml
root = pathlib.Path(sys.argv[1])
tmpdir = pathlib.Path(sys.argv[2])
upstream_path = pathlib.Path(sys.argv[3])
merge_py = pathlib.Path(sys.argv[4])
merged_vars = {}
for path in (root / "versions.yml", root / "ansible/group_vars/all.yml"):
    merged_vars.update(yaml.safe_load(path.read_text()) or {})
for role in (
    "preflight", "common", "host_firewall", "docker", "e2b_host",
    "e2b_datastores", "e2b_services", "e2b_templates", "traefik", "kodus", "doctor",
):
    defaults = root / f"ansible/roles/{role}/defaults/main.yml"
    if defaults.is_file():
        merged_vars.update(yaml.safe_load(defaults.read_text()) or {})
vars_file = tmpdir / "kodus-vars2.yml"
vars_file.write_text(yaml.safe_dump(merged_vars))
override_text = subprocess.check_output(
    ["bash", str(root / "tests/fixtures/render-template.sh"),
     "ansible/roles/kodus/templates/docker-compose.override.yml.j2", str(vars_file)],
    text=True, cwd=root,
)
override_path = tmpdir / "override2.yml"
override_path.write_text(override_text)
proc = subprocess.run(
    ["python3", str(merge_py), "check", "--base", str(upstream_path),
     "--override", str(override_path), "--require-ip", "127.0.0.1"],
    text=True, cwd=root, capture_output=True,
)
report = json.loads(proc.stdout)
if proc.returncode != 0 and "api:3999" in report.get("missing_upstream_targets", []):
    print("caught missing port")
    raise SystemExit(0)
print("did not catch extra upstream port", report)
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

mismatch_output() {
  local host="$1"
  cat <<EOF
ERROR API_GITHUB_CODE_MANAGEMENT_WEBHOOK (GitHub) host must match WEB_HOSTNAME_API (${host}).
ERROR API_GITLAB_CODE_MANAGEMENT_WEBHOOK (GitLab) host must match WEB_HOSTNAME_API (${host}).
ERROR GLOBAL_BITBUCKET_CODE_MANAGEMENT_WEBHOOK (Bitbucket) host must match WEB_HOSTNAME_API (${host}).
ERROR GLOBAL_AZURE_REPOS_CODE_MANAGEMENT_WEBHOOK (Azure Repos) host must match WEB_HOSTNAME_API (${host}).
ERROR API_FORGEJO_CODE_MANAGEMENT_WEBHOOK (Forgejo) host must match WEB_HOSTNAME_API (${host}).
EOF
}

@test "upstream doctor.sh mismatch-only diagnostics are tolerated" {
  mismatch_output kodus-api.example.com >"${WORKDIR}/doctor.out"
  run python3 "${INTERPRET_PY}" --output-file "${WORKDIR}/doctor.out" --rc 1 \
    --expected-host kodus-api.example.com
  [ "$status" -eq 0 ]
}

@test "a genuine doctor.sh error alone fails closed" {
  printf 'ERROR Docker is not installed.\n' >"${WORKDIR}/doctor.out"
  run python3 "${INTERPRET_PY}" --output-file "${WORKDIR}/doctor.out" --rc 1 \
    --expected-host kodus-api.example.com
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected"* ]]
}

@test "a genuine doctor.sh error alongside mismatches fails closed" {
  {
    mismatch_output kodus-api.example.com
    echo "ERROR Postgres is not accepting connections."
  } >"${WORKDIR}/doctor.out"
  run python3 "${INTERPRET_PY}" --output-file "${WORKDIR}/doctor.out" --rc 1 \
    --expected-host kodus-api.example.com
  [ "$status" -ne 0 ]
  [[ "$output" == *"Postgres"* ]]
}

@test "changed upstream doctor.sh wording fails closed" {
  mismatch_output kodus-api.example.com | sed 's/must match/must equal/' >"${WORKDIR}/doctor.out"
  run python3 "${INTERPRET_PY}" --output-file "${WORKDIR}/doctor.out" --rc 1 \
    --expected-host kodus-api.example.com
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed closed"* ]]
}

@test "invalid webhook host or path fails our validation" {
  render_env
  python3 - "${WORKDIR}/installer/.env" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    "https://kodus-webhooks.example.com/github/webhook",
    "http://kodus-api.example.com/github/webhook",
)
path.write_text(text)
PY
  run python3 "${VALIDATE_PY}" --env "${WORKDIR}/installer/.env" --webhooks-host kodus-webhooks.example.com
  [ "$status" -ne 0 ]
  [[ "$output" == *"https"* ]]
  render_env
  python3 - "${WORKDIR}/installer/.env" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("/gitlab/webhook", "/gitlab/hooks")
path.write_text(text)
PY
  run python3 "${VALIDATE_PY}" --env "${WORKDIR}/installer/.env" --webhooks-host kodus-webhooks.example.com
  [ "$status" -ne 0 ]
  [[ "$output" == *"path"* ]]
}

@test "fixture pin equals versions.yml kodus_installer_ref and includes doctor.sh" {
  [ -f "${FIXTURE}/scripts/doctor.sh" ]
  python3 - "${REPO_ROOT}" "${FIXTURE}" <<'PY'
import pathlib, sys, yaml
root, fixture = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
versions = yaml.safe_load((root / "versions.yml").read_text())
pin = yaml.safe_load((fixture / "PIN.yml").read_text())
assert pin["kodus_installer_ref"] == versions["kodus_installer_ref"], (pin, versions["kodus_installer_ref"])
assert (fixture / "README.md").is_file()
print("ok")
PY
}

@test "hairpin fallback sets SDK E2B_API_URL and E2B_SANDBOX_URL" {
  render_env
  [ "$(dotenv_get "${WORKDIR}/installer/.env" E2B_API_URL)" = "https://api.e2b.example.com" ]
  [ "$(dotenv_get "${WORKDIR}/installer/.env" E2B_SANDBOX_URL)" = "https://sandbox.e2b.example.com" ]
  SDK="${REPO_ROOT}/e2b/templates/node_modules/e2b/dist/index.mjs"
  cat >"${WORKDIR}/sdk-url.mjs" <<EOF
import { ConnectionConfig } from 'file://${SDK}';
const cfg = new ConnectionConfig();
if (cfg.apiUrl !== "https://api.e2b.example.com") {
  console.error("apiUrl", cfg.apiUrl);
  process.exit(1);
}
const sandboxUrl = cfg.getSandboxUrl("sbx_test", { sandboxDomain: "e2b.example.com", envdPort: 49983 });
if (sandboxUrl !== "https://sandbox.e2b.example.com") {
  console.error("sandboxUrl", sandboxUrl);
  process.exit(1);
}
console.log("ok");
EOF
  run env E2B_DOMAIN=e2b.example.com \
    E2B_API_URL=https://api.e2b.example.com \
    E2B_SANDBOX_URL=https://sandbox.e2b.example.com \
    node "${WORKDIR}/sdk-url.mjs"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
  python3 - "${WORKDIR}/config.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
cfg = json.loads(path.read_text())
cfg["hairpin_fallback"] = False
path.write_text(json.dumps(cfg))
PY
  python3 "${RENDER_PY}" \
    --example "${WORKDIR}/installer/.env.example" \
    --output "${WORKDIR}/installer/.env.nofallback" \
    --config "${WORKDIR}/config.json"
  ! grep -q '^E2B_API_URL=' "${WORKDIR}/installer/.env.nofallback"
  ! grep -q '^E2B_SANDBOX_URL=' "${WORKDIR}/installer/.env.nofallback"
}

@test "hairpin fallback is opt-in in shipped defaults" {
  python3 - "${REPO_ROOT}" <<'PY'
import pathlib, sys, yaml
root = pathlib.Path(sys.argv[1])
group = yaml.safe_load((root / "ansible/group_vars/all.yml").read_text())
defaults = yaml.safe_load((root / "ansible/roles/kodus/defaults/main.yml").read_text())
assert group["kodus_extra_hosts_hairpin"] is False, group
assert defaults["kodus_extra_hosts_hairpin"] is False, defaults
print("ok")
PY
}

@test "renderer honors alternate domain bind host and webhook host" {
  python3 - "${WORKDIR}/config.json" "${REPO_ROOT}" <<'PY'
import json, pathlib, sys, yaml
out, root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
versions = yaml.safe_load((root / "versions.yml").read_text())
cfg = {
    "qops_domain": "acme.test",
    "web_host": "kodus.acme.test",
    "api_host": "kodus-api.acme.test",
    "webhooks_host": "kodus-webhooks.acme.test",
    "web_url": "https://kodus.acme.test",
    "e2b_domain": "e2b.acme.test",
    "e2b_api_key": "e2b_" + "b" * 40,
    "image_tag": versions["kodus_image_tag"],
    "sandbox_provider": "e2b",
    "template_id": "kodus-sandbox",
    "template_graph_id": "kodus-sandbox-graph",
    "worker_role": "code-review",
    "cloud_mode": False,
    "telemetry_disabled": True,
    "license_key": "",
    "llm_provider_model": "auto",
    "openai_api_key": "sk-alt",
    "openai_force_base_url": "https://llm.acme.test/v1",
    "web_port_api": "8443",
    "hairpin_fallback": True,
    "env_overrides": {},
}
out.write_text(json.dumps(cfg))
PY
  python3 "${RENDER_PY}" \
    --example "${WORKDIR}/installer/.env.example" \
    --output "${WORKDIR}/installer/.env.alt" \
    --config "${WORKDIR}/config.json" \
    --mode 0600
  [ "$(dotenv_get "${WORKDIR}/installer/.env.alt" WEB_HOSTNAME_API)" = "kodus-api.acme.test" ]
  [ "$(dotenv_get "${WORKDIR}/installer/.env.alt" API_GITHUB_CODE_MANAGEMENT_WEBHOOK)" = "https://kodus-webhooks.acme.test/github/webhook" ]
  [ "$(dotenv_get "${WORKDIR}/installer/.env.alt" E2B_DOMAIN)" = "e2b.acme.test" ]
  [ "$(dotenv_get "${WORKDIR}/installer/.env.alt" E2B_API_URL)" = "https://api.e2b.acme.test" ]
  [ "$(dotenv_get "${WORKDIR}/installer/.env.alt" API_OPENAI_FORCE_BASE_URL)" = "https://llm.acme.test/v1" ]
  [ "$(dotenv_get "${WORKDIR}/installer/.env.alt" WEB_PORT_API)" = "8443" ]
  run bash "${CALLBACKS_SH}" https://kodus.acme.test https://kodus-webhooks.acme.test \
    https://kodus-api.acme.test "${WORKDIR}/callbacks-alt.txt"
  [[ "$output" == *"https://kodus-webhooks.acme.test/github/webhook"* ]]
}

@test "merged compose honors an alternate bind address" {
  run python3 - "${REPO_ROOT}" "${BATS_TMPDIR}" "${WORKDIR}/installer/docker-compose.yml" "${MERGE_PY}" <<'PY'
import json, pathlib, subprocess, sys, yaml
root = pathlib.Path(sys.argv[1])
tmpdir = pathlib.Path(sys.argv[2])
upstream_path = pathlib.Path(sys.argv[3])
merge_py = pathlib.Path(sys.argv[4])
merged_vars = {}
for path in (root / "versions.yml", root / "ansible/group_vars/all.yml"):
    merged_vars.update(yaml.safe_load(path.read_text()) or {})
for role in (
    "preflight", "common", "host_firewall", "docker", "e2b_host",
    "e2b_datastores", "e2b_services", "e2b_templates", "traefik", "kodus", "doctor",
):
    defaults = root / f"ansible/roles/{role}/defaults/main.yml"
    if defaults.is_file():
        merged_vars.update(yaml.safe_load(defaults.read_text()) or {})
merged_vars["kodus_bind_host"] = "127.0.0.2"
vars_file = tmpdir / "kodus-alt-bind.yml"
vars_file.write_text(yaml.safe_dump(merged_vars))
override_text = subprocess.check_output(
    ["bash", str(root / "tests/fixtures/render-template.sh"),
     "ansible/roles/kodus/templates/docker-compose.override.yml.j2", str(vars_file)],
    text=True, cwd=root,
)
assert "127.0.0.2:" in override_text
assert "0.0.0.0" not in override_text
override_path = tmpdir / "override-alt.yml"
override_path.write_text(override_text)
report = json.loads(subprocess.check_output(
    ["python3", str(merge_py), "check", "--base", str(upstream_path),
     "--override", str(override_path), "--require-ip", "127.0.0.2"],
    text=True, cwd=root,
))
assert report["ok"] is True, report
assert all(p["effective_ip"] == "127.0.0.2" for p in report["ports"]), report["ports"]
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}
