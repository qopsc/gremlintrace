#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CHECKER="${REPO_ROOT}/ci/check_workflow_job_deps.py"
}

@test "workflow jobs satisfy Python imports for invoked scripts" {
  run python3 "${CHECKER}"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "workflow dependency checker fails on undeclared PyYAML import" {
  run python3 "${CHECKER}" \
    --inject "build-e2b.yml:build-dist:tests/fixtures/workflow-bad-yaml.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"imports yaml"* ]]
}

@test "workflow dependency checker passes for real build.sh without PyYAML" {
  run python3 "${CHECKER}" \
    --inject "build-e2b.yml:build-dist:e2b/build/build.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}
