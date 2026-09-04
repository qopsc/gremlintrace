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
