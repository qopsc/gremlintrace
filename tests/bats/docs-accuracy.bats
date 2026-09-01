#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CHECKER="${REPO_ROOT}/ci/check-docs-accuracy.py"
}

@test "documentation references only existing playbooks, roles, workflows, and scripts" {
  run python3 "${CHECKER}"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "docs-accuracy checker fails on a deliberately bad playbook reference" {
  run python3 "${CHECKER}" --inject-bad-playbook not-a-real-playbook
  [ "$status" -ne 0 ]
  [[ "$output" == *"not-a-real-playbook"* ]]
}
