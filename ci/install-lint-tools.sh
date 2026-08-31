#!/usr/bin/env bash
# Install pinned lint/test tools for lint.yml (versions.yml is the only pin source).
set -euo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS_FILE="${REPO_ROOT}/versions.yml"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

yaml_get() {
  python3 "${REPO_ROOT}/ci/yaml_versions.py" get "$1" "${VERSIONS_FILE}"
}

install_actionlint() {
  local version sha url archive tmp
  version="$(yaml_get actionlint_version)"
  sha="$(yaml_get actionlint_sha256)"
  archive="actionlint_${version}_linux_amd64.tar.gz"
  url="https://github.com/rhysd/actionlint/releases/download/v${version}/${archive}"
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN
  curl -fsSL -o "${tmp}/${archive}" "${url}"
  echo "${sha}  ${archive}" | (cd "${tmp}" && sha256sum -c -)
  tar -xzf "${tmp}/${archive}" -C "${tmp}"
  sudo install -m 0755 "${tmp}/actionlint" /usr/local/bin/actionlint
}

install_actionlint

python3 -m pip install --disable-pip-version-check --user -q \
  "ansible-core==$(yaml_get ansible_core_version)" \
  "ansible-lint==$(yaml_get ansible_lint_version)" \
  "yamllint==$(yaml_get yamllint_version)"

export PATH="${HOME}/.local/bin:${PATH}"

sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  "shellcheck=$(yaml_get shellcheck_apt_version)" \
  "bats=$(yaml_get bats_apt_version)"

command -v ansible-lint >/dev/null
command -v yamllint >/dev/null
command -v shellcheck >/dev/null
command -v bats >/dev/null
actionlint -version
