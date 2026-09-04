#!/usr/bin/env bash
# Install pinned lint/test tools for lint.yml (versions.yml is the only pin source).
set -euo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS_FILE="${REPO_ROOT}/versions.yml"
VERIFY_ONLY=false

usage() {
  cat <<'EOF'
Usage: install-lint-tools.sh [--verify-only]

Install pinned lint/test tools, then verify every command make check needs.
With --verify-only, skip installation and only run the verification step.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

yaml_get() {
  python3 "${REPO_ROOT}/ci/yaml_versions.py" get "$1" "${VERSIONS_FILE}"
}

verify_make_check_tools() {
  local -a required=(
    ansible-lint
    yamllint
    shellcheck
    bats
    ansible-playbook
    python3
    npm
    node
    actionlint
  )
  local -a missing=()
  local -a failed=()
  local cmd

  for cmd in "${required[@]}"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing+=("${cmd}")
      continue
    fi
    case "${cmd}" in
      ansible-lint)
        ansible-lint --version >/dev/null 2>&1 || failed+=("${cmd}")
        ;;
      yamllint)
        yamllint --version >/dev/null 2>&1 || failed+=("${cmd}")
        ;;
      shellcheck)
        shellcheck --version >/dev/null 2>&1 || failed+=("${cmd}")
        ;;
      bats)
        bats --version >/dev/null 2>&1 || failed+=("${cmd}")
        ;;
      ansible-playbook)
        ( unset LC_ALL; ansible-playbook --version >/dev/null 2>&1 ) || failed+=("${cmd}")
        ;;
      python3)
        python3 --version >/dev/null 2>&1 || failed+=("${cmd}")
        ;;
      npm)
        npm --version >/dev/null 2>&1 || failed+=("${cmd}")
        ;;
      node)
        node --version >/dev/null 2>&1 || failed+=("${cmd}")
        ;;
      actionlint)
        actionlint -version >/dev/null 2>&1 || failed+=("${cmd}")
        ;;
    esac
  done

  if ((${#missing[@]} > 0)); then
    die "missing commands for make check: ${missing[*]}"
  fi
  if ((${#failed[@]} > 0)); then
    die "commands not runnable for make check: ${failed[*]}"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify-only)
      VERIFY_ONLY=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

if [[ "${VERIFY_ONLY}" == true ]]; then
  verify_make_check_tools
  exit 0
fi

export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"

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

sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  "shellcheck=$(yaml_get shellcheck_apt_version)" \
  "bats=$(yaml_get bats_apt_version)"

verify_make_check_tools
