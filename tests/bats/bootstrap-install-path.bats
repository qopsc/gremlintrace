#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/helpers/common.bash"

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  BOOTSTRAP="${REPO_ROOT}/bootstrap.sh"
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  STUB_BIN="${TEST_TMPDIR}/bin"
  PIPX_BIN="${TEST_TMPDIR}/pipx-bin"
  PIPX_BIN_EMPTY="${TEST_TMPDIR}/pipx-bin-empty"
  mkdir -p "${STUB_BIN}" "${PIPX_BIN}" "${PIPX_BIN_EMPTY}"

  export BOOTSTRAP_STUB_LOG="${TEST_TMPDIR}/ansible-playbook.log"
  export BOOTSTRAP_ORDER_LOG="${TEST_TMPDIR}/order.log"
  export BOOTSTRAP_PIPX_ENV_ONCE_FILE="${TEST_TMPDIR}/pipx-env-once"
  export BOOTSTRAP_PIPX_BIN="${PIPX_BIN}"
  export BOOTSTRAP_PIPX_BIN_EMPTY="${PIPX_BIN_EMPTY}"
  export BOOTSTRAP_AP_PLAYBOOK_STUB="${BATS_TEST_DIRNAME}/helpers/ansible-playbook"

  write_pipx_stub() {
    /bin/cat >"${STUB_BIN}/pipx" <<'EOF'
#!/bin/bash
printf 'pipx:%s\n' "${1:-}" >>"${BOOTSTRAP_ORDER_LOG}"
case "${1:-}" in
  environment)
    if [[ "${2:-}" == "--value" && "${3:-}" == "PIPX_BIN_DIR" ]]; then
      if [[ "${BOOTSTRAP_PIPX_USE_WRONG_BIN_ONCE:-}" == "1" && ! -f "${BOOTSTRAP_PIPX_ENV_ONCE_FILE}" ]]; then
        /usr/bin/touch "${BOOTSTRAP_PIPX_ENV_ONCE_FILE}"
        echo "${BOOTSTRAP_PIPX_BIN_EMPTY}"
      else
        echo "${BOOTSTRAP_PIPX_BIN}"
      fi
      exit 0
    fi
    ;;
  ensurepath)
    exit 0
    ;;
  install)
    if [[ "${BOOTSTRAP_PIPX_INSTALL_FAIL:-}" == "already-installed" ]]; then
      echo "pipx: already installed" >&2
      exit 1
    fi
    /bin/cp "${BOOTSTRAP_AP_PLAYBOOK_STUB}" "${BOOTSTRAP_PIPX_BIN}/ansible-playbook"
    /bin/chmod +x "${BOOTSTRAP_PIPX_BIN}/ansible-playbook"
    exit 0
    ;;
esac
exit 0
EOF
    /bin/chmod +x "${STUB_BIN}/pipx"
  }
  write_pipx_stub
  /bin/cp "${STUB_BIN}/pipx" "${TEST_TMPDIR}/pipx.stub"

  /bin/cat >"${STUB_BIN}/uname" <<'EOF'
#!/bin/bash
case "${1:-}" in -s) echo Linux ;; -m) echo x86_64 ;; esac
EOF
  /bin/chmod +x "${STUB_BIN}/uname"

  /bin/cat >"${STUB_BIN}/id" <<'EOF'
#!/bin/bash
echo 1000
EOF
  /bin/chmod +x "${STUB_BIN}/id"

  export BOOTSTRAP_TEST_PATH="${STUB_BIN}"
}

teardown() {
  /bin/rm -rf "${TEST_TMPDIR}"
}

run_bootstrap() {
  env PATH="${BOOTSTRAP_TEST_PATH}" /bin/bash "${BOOTSTRAP}" "$@"
}

assert_order_equals() {
  local -a expected=("$@")
  local -a actual=()
  while IFS= read -r order_entry; do
    actual[${#actual[@]}]="${order_entry}"
  done <"${BOOTSTRAP_ORDER_LOG}"
  if [[ "${#actual[@]}" -ne "${#expected[@]}" ]]; then
    echo "order length mismatch: got ${#actual[@]} want ${#expected[@]}" >&2
    printf '  got:  %s\n' "${actual[@]}" >&2
    printf '  want: %s\n' "${expected[@]}" >&2
    return 1
  fi
  local i
  for i in "${!expected[@]}"; do
    if [[ "${actual[$i]}" != "${expected[$i]}" ]]; then
      echo "order[$i] mismatch: got ${actual[$i]@Q} want ${expected[$i]@Q}" >&2
      return 1
    fi
  done
}

@test "pipx install path runs commands in order then ansible-playbook" {
  run run_bootstrap --syntax-check
  [ "$status" -eq 0 ]
  assert_order_equals \
    "pipx:environment" \
    "pipx:ensurepath" \
    "pipx:environment" \
    "pipx:install" \
    "pipx:environment" \
    "ansible-playbook"
  assert_argv_equals \
    "${PIPX_BIN}/ansible-playbook" \
    "${REPO_ROOT}/ansible/playbooks/site.yml" \
    "-i" \
    "${REPO_ROOT}/ansible/inventory/example.yml" \
    "--syntax-check"
}

@test "preinstalled ansible-playbook in pipx bin avoids package installation" {
  /bin/cp "${BOOTSTRAP_AP_PLAYBOOK_STUB}" "${PIPX_BIN}/ansible-playbook"
  /bin/chmod +x "${PIPX_BIN}/ansible-playbook"
  export BOOTSTRAP_PIPX_INSTALL_FAIL=already-installed
  export BOOTSTRAP_PIPX_USE_WRONG_BIN_ONCE=1

  run run_bootstrap --syntax-check
  [ "$status" -eq 0 ]
  assert_order_equals \
    "pipx:environment" \
    "pipx:ensurepath" \
    "pipx:environment" \
    "ansible-playbook"
  assert_argv_equals \
    "${PIPX_BIN}/ansible-playbook" \
    "${REPO_ROOT}/ansible/playbooks/site.yml" \
    "-i" \
    "${REPO_ROOT}/ansible/inventory/example.yml" \
    "--syntax-check"
}

@test "pipx missing triggers apt-get and sudo in documented order" {
  /bin/rm -f "${STUB_BIN}/pipx"
  /bin/cp "${TEST_TMPDIR}/pipx.stub" "${STUB_BIN}/pipx.template"
  /bin/cat >"${STUB_BIN}/apt-get" <<'EOF'
#!/bin/bash
printf 'apt-get\n' >>"${BOOTSTRAP_ORDER_LOG}"
if [[ "${1:-}" == "install" && "$*" == *pipx* ]]; then
  /bin/cp "${BOOTSTRAP_PIPX_STUB_TEMPLATE}" "${BOOTSTRAP_STUB_BIN}/pipx"
  /bin/chmod +x "${BOOTSTRAP_STUB_BIN}/pipx"
fi
exit 0
EOF
  /bin/chmod +x "${STUB_BIN}/apt-get"
  /bin/cat >"${STUB_BIN}/sudo" <<'EOF'
#!/bin/bash
printf 'sudo\n' >>"${BOOTSTRAP_ORDER_LOG}"
exec "$@"
EOF
  /bin/chmod +x "${STUB_BIN}/sudo"
  export BOOTSTRAP_PIPX_STUB_TEMPLATE="${STUB_BIN}/pipx.template"
  export BOOTSTRAP_STUB_BIN="${STUB_BIN}"

  run run_bootstrap --syntax-check
  [ "$status" -eq 0 ]
  assert_order_equals \
    "sudo" \
    "apt-get" \
    "sudo" \
    "apt-get" \
    "pipx:ensurepath" \
    "pipx:environment" \
    "pipx:install" \
    "pipx:environment" \
    "ansible-playbook"
}
