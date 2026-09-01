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

@test "docs-accuracy checker fails when spike-notes.md has all - [ ] removed" {
  run python3 "${CHECKER}" --inject-spike-notes-no-checkboxes
  [ "$status" -ne 0 ]
  [[ "$output" == *"- [ ]"* ]]
  [[ "$output" != *"must not claim Phase 0"* ]]
  [[ "$output" != *"must not call Ubuntu 24.04"* ]]
}

@test "docs-accuracy checker fails when spike-notes.md claims Phase 0 complete" {
  run python3 "${CHECKER}" --inject-spike-notes-phase-0-complete
  [ "$status" -ne 0 ]
  [[ "$output" == *"must not claim Phase 0 passed or complete"* ]]
  [[ "$output" != *"unchecked Phase 0 gates"* ]]
  [[ "$output" != *"must not call Ubuntu 24.04"* ]]
}

@test "docs-accuracy checker fails when Ubuntu 24.04 is called Supported" {
  run python3 "${CHECKER}" --inject-ubuntu-supported
  [ "$status" -ne 0 ]
  [[ "$output" == *"must not call Ubuntu 24.04 'Supported'"* ]]
  [[ "$output" != *"must not claim Phase 0"* ]]
  [[ "$output" != *"unchecked Phase 0 gates"* ]]
}
