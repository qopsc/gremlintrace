#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  INSTALL_SH="${REPO_ROOT}/ci/install-lint-tools.sh"
  export PATH="$HOME/.nvm/versions/node/v22.22.2/bin:$HOME/.local/bin:/usr/local/bin:$PATH"
}

@test "install-lint-tools --verify-only succeeds when make check tools are present" {
  run "${INSTALL_SH}" --verify-only
  [ "$status" -eq 0 ]
}

@test "install-lint-tools --verify-only fails listing a missing command" {
  local stub="${BATS_TMPDIR}/bin"
  mkdir -p "${stub}"
  for cmd in ansible-lint yamllint shellcheck bats ansible-playbook python3 npm node actionlint; do
    if [[ "${cmd}" == "bats" ]]; then
      continue
    fi
    printf '#!/bin/bash\nexit 0\n' >"${stub}/${cmd}"
    chmod +x "${stub}/${cmd}"
  done
  run env PATH="${stub}" /bin/bash "${INSTALL_SH}" --verify-only
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing commands for make check"* ]]
  [[ "$output" == *"bats"* ]]
}

@test "install-lint-tools without installation or verify would be a no-op failure" {
  local stub="${BATS_TMPDIR}/bin"
  mkdir -p "${stub}"
  run env PATH="${stub}" /bin/bash "${INSTALL_SH}" --verify-only
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing commands for make check"* ]]
}
