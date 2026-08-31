#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  BOOTSTRAP="${REPO_ROOT}/bootstrap.sh"
}

@test "bootstrap installs ansible via pipx inside ubuntu container from clean base" {
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
      command -v pipx >/dev/null 2>&1 && exit 1
      command -v ansible-playbook >/dev/null 2>&1 && exit 1
      ./bootstrap.sh --syntax-check
    '
  [ "$status" -eq 0 ]
  [[ "$output" == *"--syntax-check"* ]]
}
