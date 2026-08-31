#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/helpers/common.bash"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  STUB_BIN="${TEST_TMPDIR}/bin"
  mkdir -p "${STUB_BIN}"

  export BOOTSTRAP_STUB_LOG="${TEST_TMPDIR}/ansible-playbook.log"
  cp "${BATS_TEST_DIRNAME}/helpers/ansible-playbook" "${STUB_BIN}/ansible-playbook"
  chmod +x "${STUB_BIN}/ansible-playbook"

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

@test "non-x86_64 arch is rejected" {
  cat >"${STUB_BIN}/uname" <<'EOF'
#!/bin/bash
case "${1:-}" in
  -s) echo Linux ;;
  -m) echo "${BOOTSTRAP_STUB_UNAME_M:-x86_64}" ;;
  *) command -v /usr/bin/uname >/dev/null 2>&1 && exec /usr/bin/uname "$@" || exec /bin/uname "$@" ;;
esac
EOF
  chmod +x "${STUB_BIN}/uname"
  run env PATH="${STUB_BIN}:${PATH}" BOOTSTRAP_STUB_UNAME_M=aarch64 \
    "${BOOTSTRAP}" --skip-install
  [ "$status" -ne 0 ]
  [[ "$output" == *"x86_64"* ]]
}
