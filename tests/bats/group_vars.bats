#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export ANSIBLE_CONFIG="${REPO_ROOT}/ansible.cfg"
  export ANSIBLE_HOST_KEY_CHECKING=False
  INVENTORY="${REPO_ROOT}/tests/fixtures/inventory-codereviewer-local.yml"
  DOCTOR_PLAYBOOK="${REPO_ROOT}/ansible/playbooks/doctor.yml"
}

@test "doctor.yml --check resolves group_vars and versions via playbook vars_files" {
  run ansible-playbook --check -i "${INVENTORY}" "${DOCTOR_PLAYBOOK}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Verify operator and pin variables resolve from vars_files"* ]]
  [[ "$output" == *"All assertions passed"* ]]
  [[ "$output" != *"FAILED"* ]]
}

@test "tls_mode default in group_vars/all.yml is acme_dns" {
  run grep -E '^tls_mode:[[:space:]]*"?acme_dns"?[[:space:]]*$' \
    "${REPO_ROOT}/ansible/group_vars/all.yml"
  [ "$status" -eq 0 ]
}

@test "doctor.yml rejects an out-of-range tls_mode" {
  run ansible-playbook --check -i "${INVENTORY}" "${DOCTOR_PLAYBOOK}" \
    --extra-vars "tls_mode=bogus"
  [ "$status" -ne 0 ]
  [[ "$output" == *"vars_files did not load"* ]]
}

@test "doctor.yml rejects kodus_image_tag=latest" {
  run ansible-playbook --check -i "${INVENTORY}" "${DOCTOR_PLAYBOOK}" \
    --extra-vars "kodus_image_tag=latest"
  [ "$status" -ne 0 ]
}
