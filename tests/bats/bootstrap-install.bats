#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  BOOTSTRAP="${REPO_ROOT}/bootstrap.sh"
}

@test "bootstrap installs ansible via pipx inside ubuntu container" {
  if ! command -v docker >/dev/null 2>&1; then
    skip "docker not on PATH; container install path unverified on this machine"
  fi

  run docker run --rm \
    -v "${REPO_ROOT}:/codereviewer:ro" \
    -w /codereviewer \
    ubuntu:24.04 \
    /bin/bash -lc '
      set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq python3 python3-venv pipx ca-certificates git
      pipx ensurepath
      export PATH="/root/.local/bin:${PATH}"
      ./bootstrap.sh --syntax-check
    '
  [ "$status" -eq 0 ]
  [[ "$output" == *"--syntax-check"* ]]
}
