#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/helpers/common.bash"

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  BOOTSTRAP="${REPO_ROOT}/bootstrap.sh"
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  STUB_BIN="${TEST_TMPDIR}/bin"
  PIPX_BIN="${TEST_TMPDIR}/pipx-bin"
  mkdir -p "${STUB_BIN}" "${PIPX_BIN}"

  export BOOTSTRAP_STUB_LOG="${TEST_TMPDIR}/ansible-playbook.log"
  export BOOTSTRAP_PIPX_LOG="${TEST_TMPDIR}/pipx.log"
  export BOOTSTRAP_PIPX_BIN="${PIPX_BIN}"
  export BOOTSTRAP_AP_PLAYBOOK_STUB="${BATS_TEST_DIRNAME}/helpers/ansible-playbook"

  write_pipx_stub() {
    cat >"${STUB_BIN}/pipx" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >>"${BOOTSTRAP_PIPX_LOG}"
case "${1:-}" in
  environment)
    if [[ "${2:-}" == "--value" && "${3:-}" == "PIPX_BIN_DIR" ]]; then
      echo "${BOOTSTRAP_PIPX_BIN}"
      exit 0
    fi
    ;;
  ensurepath)
    exit 0
    ;;
  install)
    /bin/cp "${BOOTSTRAP_AP_PLAYBOOK_STUB}" "${BOOTSTRAP_PIPX_BIN}/ansible-playbook"
    /bin/chmod +x "${BOOTSTRAP_PIPX_BIN}/ansible-playbook"
    if [[ "${BOOTSTRAP_PIPX_INSTALL_FAIL:-}" == "already-installed" ]]; then
      exit 1
    fi
    exit 0
    ;;
esac
exit 0
EOF
    chmod +x "${STUB_BIN}/pipx"
  }
  write_pipx_stub
  cp "${STUB_BIN}/pipx" "${TEST_TMPDIR}/pipx.stub"

  cat >"${STUB_BIN}/uname" <<'EOF'
#!/bin/bash
case "${1:-}" in -s) echo Linux ;; -m) echo x86_64 ;; esac
EOF
  chmod +x "${STUB_BIN}/uname"

  cat >"${STUB_BIN}/id" <<'EOF'
#!/bin/bash
echo 1000
EOF
  chmod +x "${STUB_BIN}/id"

  export BOOTSTRAP_TEST_PATH="${STUB_BIN}"
}

teardown() {
  /bin/rm -rf "${TEST_TMPDIR}"
}

run_bootstrap() {
  env PATH="${BOOTSTRAP_TEST_PATH}" /bin/bash "${BOOTSTRAP}" "$@"
}

@test "pipx install path runs pipx install then ansible-playbook when ansible is missing" {
  run run_bootstrap --syntax-check
  [ "$status" -eq 0 ]
  /usr/bin/grep -Fxq 'ensurepath' "${BOOTSTRAP_PIPX_LOG}"
  /usr/bin/grep -Fxq 'install' "${BOOTSTRAP_PIPX_LOG}"
  /usr/bin/grep -Fxq -- '--include-deps' "${BOOTSTRAP_PIPX_LOG}"
  /usr/bin/grep -Fxq 'ansible' "${BOOTSTRAP_PIPX_LOG}"
  assert_argv_equals \
    "${PIPX_BIN}/ansible-playbook" \
    "${REPO_ROOT}/ansible/playbooks/site.yml" \
    "-i" \
    "${REPO_ROOT}/ansible/inventory/example.yml" \
    "--syntax-check"
}

@test "pipx install failure still succeeds when ansible-playbook is in pipx bin dir" {
  export BOOTSTRAP_PIPX_INSTALL_FAIL=already-installed

  run run_bootstrap --syntax-check
  [ "$status" -eq 0 ]
  /usr/bin/grep -Fxq 'install' "${BOOTSTRAP_PIPX_LOG}"
  assert_argv_equals \
    "${PIPX_BIN}/ansible-playbook" \
    "${REPO_ROOT}/ansible/playbooks/site.yml" \
    "-i" \
    "${REPO_ROOT}/ansible/inventory/example.yml" \
    "--syntax-check"
}

@test "pipx missing triggers apt-get install via sudo in documented order" {
  /bin/rm -f "${STUB_BIN}/pipx"
  /bin/cp "${TEST_TMPDIR}/pipx.stub" "${STUB_BIN}/pipx.template"
  /bin/cat >"${STUB_BIN}/apt-get" <<'EOF'
#!/bin/bash
printf 'apt-get %s\n' "$*" >>"${BOOTSTRAP_PIPX_LOG}"
if [[ "${1:-}" == "install" && "$*" == *pipx* ]]; then
  /bin/cp "${BOOTSTRAP_PIPX_STUB_TEMPLATE}" "${BOOTSTRAP_STUB_BIN}/pipx"
  /bin/chmod +x "${BOOTSTRAP_STUB_BIN}/pipx"
fi
exit 0
EOF
  /bin/chmod +x "${STUB_BIN}/apt-get"
  /bin/cat >"${STUB_BIN}/sudo" <<'EOF'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"${BOOTSTRAP_PIPX_LOG}"
exec "$@"
EOF
  /bin/chmod +x "${STUB_BIN}/sudo"
  export BOOTSTRAP_PIPX_STUB_TEMPLATE="${STUB_BIN}/pipx.template"
  export BOOTSTRAP_STUB_BIN="${STUB_BIN}"

  run run_bootstrap --syntax-check
  [ "$status" -eq 0 ]
  /usr/bin/grep -Fq 'apt-get update' "${BOOTSTRAP_PIPX_LOG}"
  /usr/bin/grep -Fq 'apt-get install -y pipx' "${BOOTSTRAP_PIPX_LOG}"
  /usr/bin/grep -Fq 'sudo apt-get update' "${BOOTSTRAP_PIPX_LOG}"
  /usr/bin/grep -Fq 'sudo apt-get install -y pipx' "${BOOTSTRAP_PIPX_LOG}"
}
