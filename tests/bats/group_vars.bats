#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export ANSIBLE_CONFIG="${REPO_ROOT}/ansible.cfg"
  export ANSIBLE_HOST_KEY_CHECKING=False
  INVENTORY="${REPO_ROOT}/tests/fixtures/inventory-codereviewer-local.yml"
  DOCTOR_PLAYBOOK="${REPO_ROOT}/ansible/playbooks/doctor.yml"
}

@test "doctor.yml --check resolves documented defaults and versions" {
  run ansible-playbook --check -i "${INVENTORY}" "${DOCTOR_PLAYBOOK}" \
    --extra-vars "ansible_become=false"
  [ "$status" -eq 0 ]
  [[ "$output" == *"operator and pin variables resolved"* ]]
  [[ "$output" == *"qops_domain=example.com"* ]]
  [[ "$output" == *"tls_mode=acme_dns"* ]]
  [[ "$output" != *"FAILED"* ]]
}

@test "inventory operator values override documented defaults" {
  OPERATOR_INVENTORY="${REPO_ROOT}/tests/fixtures/inventory-codereviewer-operator.yml"
  run ansible-playbook --check -i "${OPERATOR_INVENTORY}" "${DOCTOR_PLAYBOOK}" \
    --extra-vars "ansible_become=false"
  [ "$status" -eq 0 ]
  [[ "$output" == *"qops_domain=customer.example.net"* ]]
  [[ "$output" == *"tls_mode=provided"* ]]
  [[ "$output" != *"FAILED"* ]]
}

@test "extra vars still override inventory operator values" {
  OPERATOR_INVENTORY="${REPO_ROOT}/tests/fixtures/inventory-codereviewer-operator.yml"
  run ansible-playbook --check -i "${OPERATOR_INVENTORY}" "${DOCTOR_PLAYBOOK}" \
    --extra-vars "ansible_become=false" \
    --extra-vars "tls_mode=internal_ca"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tls_mode=internal_ca"* ]]
  [[ "$output" != *"FAILED"* ]]
}

@test "all playbooks load inventory-overridable defaults" {
  for playbook in "${REPO_ROOT}"/ansible/playbooks/*.yml; do
    run ansible-playbook --list-tasks -i "${INVENTORY}" "${playbook}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Load documented defaults without overriding inventory"* ]]
  done
}

@test "tls_mode default in group_vars/all.yml is acme_dns" {
  run grep -E '^tls_mode:[[:space:]]*"?acme_dns"?[[:space:]]*$' \
    "${REPO_ROOT}/ansible/group_vars/all.yml"
  [ "$status" -eq 0 ]
}

@test "doctor.yml rejects an out-of-range tls_mode" {
  run ansible-playbook --check -i "${INVENTORY}" "${DOCTOR_PLAYBOOK}" \
    --extra-vars "ansible_become=false" \
    --extra-vars "tls_mode=bogus"
  [ "$status" -ne 0 ]
  [[ "$output" == *"tls_mode=bogus"* ]]
}

@test "doctor.yml rejects kodus_image_tag=latest" {
  run ansible-playbook --check -i "${INVENTORY}" "${DOCTOR_PLAYBOOK}" \
    --extra-vars "ansible_become=false" \
    --extra-vars "kodus_image_tag=latest"
  [ "$status" -ne 0 ]
}

@test "ansible.cfg enables the community.sops vars plugin beside host_group_vars" {
  run env ANSIBLE_CONFIG="${REPO_ROOT}/ansible.cfg" ansible-config dump --only-changed
  [ "$status" -eq 0 ]
  [[ "$output" == *"VARIABLE_PLUGINS_ENABLED"* ]]
  [[ "$output" == *"host_group_vars"* ]]
  [[ "$output" == *"community.sops.sops"* ]]
}

@test "sops-encrypted host_vars decrypt transparently with an age key" {
  if ! command -v sops >/dev/null 2>&1 || ! command -v age-keygen >/dev/null 2>&1; then
    skip "sops and age are not installed on this machine"
  fi
  work="${BATS_TMPDIR}/sops-inv"
  rm -rf "${work}"
  mkdir -p "${work}/host_vars/box1"
  age-keygen -o "${work}/age.txt" 2>/dev/null
  recipient="$(grep -o 'age1[0-9a-z]*' "${work}/age.txt" | head -n1)"
  cat >"${work}/inventory.yml" <<'YML'
all:
  children:
    codereviewer:
      hosts:
        box1:
          ansible_connection: local
YML
  printf 'tls_acme_dns_credentials:\n  PORKBUN_API_KEY: pk_live_unit\n' >"${work}/host_vars/box1/secrets.sops.yml"
  # sops resolves .sops.yaml from the working directory upward; run from the
  # scratch tree so the repo config (which only covers ansible/inventory) is not used.
  (cd "${work}" && SOPS_AGE_KEY_FILE="${work}/age.txt" sops --encrypt --age "${recipient}" --in-place host_vars/box1/secrets.sops.yml)
  grep -q 'ENC\[' "${work}/host_vars/box1/secrets.sops.yml"
  run env ANSIBLE_CONFIG="${REPO_ROOT}/ansible.cfg" SOPS_AGE_KEY_FILE="${work}/age.txt" \
    ansible -i "${work}/inventory.yml" box1 -m debug -a "var=tls_acme_dns_credentials.PORKBUN_API_KEY"
  echo "${output}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pk_live_unit"* ]]
}

@test "repo .sops.yaml encrypts host_vars secrets with age and ships an example file" {
  cfg="${REPO_ROOT}/.sops.yaml"
  [ -f "${cfg}" ]
  run python3 - "${cfg}" <<'PY'
import re, sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
rules = cfg["creation_rules"]
target = "ansible/inventory/host_vars/box1/secrets.sops.yml"
match = [r for r in rules if re.search(r["path_regex"], target)]
assert match, "no creation rule matches %s" % target
rule = match[0]
assert "age" in rule, "rule must use age recipients"
assert not any(k in rule for k in ("kms", "gcp_kms", "azure_keyvault", "pgp")), "age only"
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
  example="${REPO_ROOT}/ansible/inventory/host_vars/example-host/secrets.sops.yml.example"
  [ -f "${example}" ]
  grep -q '^tls_acme_dns_credentials:' "${example}"
  grep -q '^kodus_openai_api_key:' "${example}"
  grep -q '^kodus_license_key:' "${example}"
}
