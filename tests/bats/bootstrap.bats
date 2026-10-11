#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/helpers/common.bash"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  export HOME="${TEST_TMPDIR}/home"
  mkdir -p "${HOME}"

  export STUB_BIN="${TEST_TMPDIR}/bin"
  mkdir -p "${STUB_BIN}"

  export BOOTSTRAP_STUB_LOG="${TEST_TMPDIR}/ansible-playbook.log"
  export BOOTSTRAP_ORDER_LOG="${TEST_TMPDIR}/order.log"
  cp "${BATS_TEST_DIRNAME}/helpers/ansible-playbook" "${STUB_BIN}/ansible-playbook"
  chmod +x "${STUB_BIN}/ansible-playbook"

  cat >"${STUB_BIN}/pipx" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "environment" && "${2:-}" == "--value" && "${3:-}" == "PIPX_BIN_DIR" ]]; then
  printf '%s\n' "${STUB_BIN}"
fi
EOF
  chmod +x "${STUB_BIN}/pipx"

  # Exercise the Linux-only entry point consistently on the macOS control host.
  cat >"${STUB_BIN}/uname" <<'EOF'
#!/bin/bash
case "${1:-}" in
  -s) echo Linux ;;
  -m) echo x86_64 ;;
esac
EOF
  chmod +x "${STUB_BIN}/uname"

  export PATH="${STUB_BIN}:${PATH}"
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  BOOTSTRAP="${REPO_ROOT}/bootstrap.sh"
}

teardown() {
  /bin/rm -rf "${TEST_TMPDIR}"
}

@test "--help exits 0 and prints usage" {
  run "${BOOTSTRAP}" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: bootstrap.sh"* ]]
  [[ "$output" == *"--syntax-check"* ]]
}

@test "unknown flag exits non-zero and writes to stderr" {
  run "${BOOTSTRAP}" --not-a-real-flag
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option"* ]]
}

@test "default invocation calls ansible-playbook with exact argv" {
  run "${BOOTSTRAP}" --skip-install
  [ "$status" -eq 0 ]
  assert_argv_equals \
    "${STUB_BIN}/ansible-playbook" \
    "${REPO_ROOT}/ansible/playbooks/site.yml" \
    "-i" \
    "${REPO_ROOT}/ansible/inventory/example.yml"
}

@test "bare script invocation resolves the repository directory" {
  run env PATH="${STUB_BIN}:${PATH}" /bin/bash -c \
    'cd "$1" && bash bootstrap.sh --skip-install' _ "${REPO_ROOT}"
  [ "$status" -eq 0 ]
  assert_argv_equals \
    "${STUB_BIN}/ansible-playbook" \
    "${REPO_ROOT}/ansible/playbooks/site.yml" \
    "-i" \
    "${REPO_ROOT}/ansible/inventory/example.yml"
}

@test "default invocation handles an empty extra-vars array under system Bash" {
  run /bin/bash "${BOOTSTRAP}" --skip-install
  [ "$status" -eq 0 ]
  assert_argv_equals \
    "${STUB_BIN}/ansible-playbook" \
    "${REPO_ROOT}/ansible/playbooks/site.yml" \
    "-i" \
    "${REPO_ROOT}/ansible/inventory/example.yml"
}

@test "--syntax-check forwards exact argv" {
  run "${BOOTSTRAP}" --skip-install --syntax-check
  [ "$status" -eq 0 ]
  assert_argv_equals \
    "${STUB_BIN}/ansible-playbook" \
    "${REPO_ROOT}/ansible/playbooks/site.yml" \
    "-i" \
    "${REPO_ROOT}/ansible/inventory/example.yml" \
    "--syntax-check"
}

@test "--inventory and --playbook forward exact argv" {
  INV="${TEST_TMPDIR}/custom inventory/example.yml"
  mkdir -p "$(dirname "${INV}")"
  cp "${REPO_ROOT}/ansible/inventory/example.yml" "${INV}"
  run "${BOOTSTRAP}" --skip-install --playbook doctor --inventory "${INV}"
  [ "$status" -eq 0 ]
  assert_argv_equals \
    "${STUB_BIN}/ansible-playbook" \
    "${REPO_ROOT}/ansible/playbooks/doctor.yml" \
    "-i" \
    "${INV}"
}

@test "--check --limit --tags and repeated -e forward exact argv in order" {
  run "${BOOTSTRAP}" --skip-install \
    --check \
    --limit "myhost" \
    --tags "docker,kodus" \
    -e "foo=bar" \
    -e "baz=qux"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--extra-vars [REDACTED]"* ]]
  [[ "$output" != *"foo=bar"* ]]
  [[ "$output" != *"baz=qux"* ]]
  assert_argv_equals \
    "${STUB_BIN}/ansible-playbook" \
    "${REPO_ROOT}/ansible/playbooks/site.yml" \
    "-i" \
    "${REPO_ROOT}/ansible/inventory/example.yml" \
    "--limit" "myhost" \
    "--tags" "docker,kodus" \
    "--check" \
    "--extra-vars" "foo=bar" \
    "--extra-vars" "baz=qux"
}

@test "--skip-install without ansible-playbook exits non-zero with helpful message" {
  EMPTY_BIN="${TEST_TMPDIR}/empty-bin"
  mkdir -p "${EMPTY_BIN}"
  cat >"${EMPTY_BIN}/uname" <<'EOF'
#!/bin/bash
case "${1:-}" in
  -s) echo Linux ;;
  -m) echo x86_64 ;;
esac
EOF
  chmod +x "${EMPTY_BIN}/uname"
  run env PATH="${EMPTY_BIN}" /bin/bash "${BOOTSTRAP}" --skip-install
  [ "$status" -ne 0 ]
  [[ "$output" == *"ansible-playbook not found"* ]]
}

@test "a macOS or arm64 control machine can drive a remote install" {
  # The x86_64/Linux requirement is the target's (preflight enforces it);
  # the controller only runs ansible-playbook over SSH.
  cat >"${STUB_BIN}/uname" <<'EOF'
#!/bin/bash
case "${1:-}" in
  -s) echo Darwin ;;
  -m) echo arm64 ;;
esac
EOF
  chmod +x "${STUB_BIN}/uname"
  run "${BOOTSTRAP}" --skip-install --syntax-check
  echo "${output}"
  [ "$status" -eq 0 ]
  grep -q '^ansible-playbook' "${BOOTSTRAP_ORDER_LOG}"
}

write_galaxy_stub() {
  # $1 = what `collection list` prints (installed collections)
  cat >"${STUB_BIN}/ansible-galaxy" <<EOF
#!/bin/bash
printf 'ansible-galaxy %s\n' "\$*" >>"${BOOTSTRAP_ORDER_LOG}"
if [[ "\${1:-}" == "collection" && "\${2:-}" == "list" ]]; then
  printf '%s\n' "${1}"
fi
exit 0
EOF
  chmod +x "${STUB_BIN}/ansible-galaxy"
}

pin() {
  python3 "${REPO_ROOT}/ci/yaml_versions.py" get "$1" "${REPO_ROOT}/versions.yml"
}

@test "bootstrap installs missing pinned collections before running the playbook" {
  write_galaxy_stub ""
  run "${BOOTSTRAP}" --skip-install --syntax-check
  echo "${output}"
  [ "$status" -eq 0 ]
  grep -q "ansible-galaxy collection install .*ansible.posix:$(pin ansible_posix_version)" "${BOOTSTRAP_ORDER_LOG}"
  grep -q "ansible-galaxy collection install .*community.general:$(pin community_general_version)" "${BOOTSTRAP_ORDER_LOG}"
  grep -q "ansible-galaxy collection install .*community.sops:$(pin community_sops_version)" "${BOOTSTRAP_ORDER_LOG}"
  install_line="$(grep -n 'ansible-galaxy collection install' "${BOOTSTRAP_ORDER_LOG}" | head -n1 | cut -d: -f1)"
  play_line="$(grep -n '^ansible-playbook' "${BOOTSTRAP_ORDER_LOG}" | head -n1 | cut -d: -f1)"
  [ "${install_line}" -lt "${play_line}" ]
}

@test "bootstrap skips collection install when the pinned versions are already present" {
  write_galaxy_stub "$(printf 'ansible.posix %s\ncommunity.general %s\ncommunity.sops %s' \
    "$(pin ansible_posix_version)" "$(pin community_general_version)" "$(pin community_sops_version)")"
  run "${BOOTSTRAP}" --skip-install --syntax-check
  [ "$status" -eq 0 ]
  ! grep -q 'ansible-galaxy collection install' "${BOOTSTRAP_ORDER_LOG}"
}

# --- sops / age controller prerequisites -------------------------------------

make_sops_inventory() {
  local inv="${TEST_TMPDIR}/sops-inv"
  mkdir -p "${inv}/host_vars/box1"
  cp "${REPO_ROOT}/ansible/inventory/example.yml" "${inv}/example.yml"
  printf 'sops:\n  age: []\n' >"${inv}/host_vars/box1/secrets.sops.yml"
  printf '%s\n' "${inv}/example.yml"
}

@test "bootstrap refuses to run when encrypted host_vars exist but sops is missing" {
  inv="$(make_sops_inventory)"
  run "${BOOTSTRAP}" --skip-install --syntax-check --inventory "${inv}"
  echo "${output}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sops"* ]]
  [[ "$output" == *"secrets.sops.yml"* ]]
  ! grep -q '^ansible-playbook' "${BOOTSTRAP_ORDER_LOG}" 2>/dev/null
}

@test "bootstrap refuses to run when sops is present but no age key is configured" {
  inv="$(make_sops_inventory)"
  printf '#!/bin/bash\nexit 0\n' >"${STUB_BIN}/sops"
  chmod +x "${STUB_BIN}/sops"
  run env -u SOPS_AGE_KEY -u SOPS_AGE_KEY_FILE XDG_CONFIG_HOME="${TEST_TMPDIR}/nocfg" \
    "${BOOTSTRAP}" --skip-install --syntax-check --inventory "${inv}"
  echo "${output}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"age"* ]]
  [[ "$output" == *"SOPS_AGE_KEY_FILE"* ]]
}

@test "bootstrap proceeds when sops and an age key file are available" {
  inv="$(make_sops_inventory)"
  printf '#!/bin/bash\nexit 0\n' >"${STUB_BIN}/sops"
  chmod +x "${STUB_BIN}/sops"
  printf 'AGE-SECRET-KEY-1TEST\n' >"${TEST_TMPDIR}/age.txt"
  run env SOPS_AGE_KEY_FILE="${TEST_TMPDIR}/age.txt" \
    "${BOOTSTRAP}" --skip-install --syntax-check --inventory "${inv}"
  echo "${output}"
  [ "$status" -eq 0 ]
  grep -q '^ansible-playbook' "${BOOTSTRAP_ORDER_LOG}"
}

@test "bootstrap does not require sops when the inventory has no encrypted files" {
  run "${BOOTSTRAP}" --skip-install --syntax-check
  [ "$status" -eq 0 ]
}
