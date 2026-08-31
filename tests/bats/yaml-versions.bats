#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  YAML_PY="${REPO_ROOT}/ci/yaml_versions.py"
  VERSIONS_FILE="${REPO_ROOT}/versions.yml"
}

@test "yaml_versions.py reads scalar values from versions.yml" {
  run python3 "${YAML_PY}" get e2b_pin "${VERSIONS_FILE}"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9a-f]{40}$ ]]
}

@test "yaml_versions.py rejects flow mapping values" {
  local bad="${BATS_TMPDIR}/flow-mapping.yml"
  cat >"${bad}" <<'EOF'
e2b_pin: {value: abcdefabcdefabcdefabcdefabcdefabcdefabcd}
EOF
  run python3 "${YAML_PY}" get e2b_pin "${bad}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"flow mapping/sequence not allowed"* ]]
}

@test "yaml_versions.py rejects flow sequence values" {
  local bad="${BATS_TMPDIR}/flow-sequence.yml"
  cat >"${bad}" <<'EOF'
e2b_pin: [abcdefabcdefabcdefabcdefabcdefabcdefabcd]
EOF
  run python3 "${YAML_PY}" get e2b_pin "${bad}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"flow mapping/sequence not allowed"* ]]
}

@test "yaml_versions.py rejects duplicate top-level keys" {
  local bad="${BATS_TMPDIR}/duplicate.yml"
  cat >"${bad}" <<'EOF'
e2b_pin: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
e2b_pin: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
EOF
  run python3 "${YAML_PY}" get e2b_pin "${bad}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate key"* ]]
}

@test "yaml_versions.py rejects missing keys" {
  run python3 "${YAML_PY}" get definitely_missing_key "${VERSIONS_FILE}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing key"* ]]
}

@test "yaml_versions.py rejects empty scalar values" {
  local bad="${BATS_TMPDIR}/empty.yml"
  printf 'e2b_pin: ""\n' >"${bad}"
  run python3 "${YAML_PY}" get e2b_pin "${bad}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty value"* ]]
}
