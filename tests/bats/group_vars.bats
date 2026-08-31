#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export ANSIBLE_CONFIG="${REPO_ROOT}/ansible.cfg"
  export ANSIBLE_HOST_KEY_CHECKING=False
}

@test "group_vars/all.yml tls_mode resolves when loaded via vars_files" {
  run ansible-playbook --check "${REPO_ROOT}/tests/fixtures/verify-group-vars.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok:"* ]]
  [[ "$output" != *"FAILED"* ]]
}
