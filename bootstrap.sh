#!/usr/bin/env bash
# Thin entry point: ensure Ansible is available, then run ansible-playbook.
set -euo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
export ANSIBLE_CONFIG="${SCRIPT_DIR}/ansible.cfg"

INVENTORY="${SCRIPT_DIR}/ansible/inventory/example.yml"
PLAYBOOK_NAME="site"
LIMIT=""
TAGS=""
CHECK=false
SYNTAX_CHECK=false
SKIP_INSTALL=false
EXTRA_VARS=()

usage() {
  cat <<'EOF'
Usage: bootstrap.sh [OPTIONS]

Run the codereviewer Ansible installer.

Options:
  -h, --help              Show this help and exit
      --inventory PATH    Ansible inventory file (default: ansible/inventory/example.yml)
      --playbook NAME     Playbook name without .yml (default: site)
      --limit HOST        Limit to hosts (ansible --limit)
      --tags TAGS         Run only tagged tasks (ansible --tags)
      --check             Dry run (ansible --check)
      --syntax-check      Validate playbook syntax and exit
      --skip-install      Do not install Ansible via pipx when missing
  -e, --extra-vars KEY=VALUE
                          Extra variable (repeatable)

Examples:
  ./bootstrap.sh --syntax-check
  ./bootstrap.sh --playbook doctor --limit myhost.example.com
EOF
}

log() {
  printf '%s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

require_linux_x86_64() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  if [[ "${os}" != "Linux" ]]; then
    die "codereviewer v1 supports Linux hosts only (detected: ${os})"
  fi
  if [[ "${arch}" != "x86_64" ]]; then
    die "codereviewer v1 supports x86_64 only (detected: ${arch})"
  fi
}

detect_os_family() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    case "${ID:-}" in
      ubuntu|debian) echo "debian" ;;
      fedora|rhel|centos|rocky|almalinux) echo "redhat" ;;
      *) echo "unknown" ;;
    esac
  else
    echo "unknown"
  fi
}

install_pipx() {
  local family
  family="$(detect_os_family)"
  case "${family}" in
    debian)
      if command -v apt-get >/dev/null 2>&1; then
        if [[ "$(id -u)" -eq 0 ]]; then
          apt-get update -qq
          apt-get install -y pipx
        elif command -v sudo >/dev/null 2>&1; then
          sudo apt-get update -qq
          sudo apt-get install -y pipx
        else
          die "pipx not found; install pipx manually or re-run as root"
        fi
      else
        die "apt-get not found; install pipx manually"
      fi
      ;;
    redhat)
      if command -v dnf >/dev/null 2>&1; then
        if [[ "$(id -u)" -eq 0 ]]; then
          dnf install -y pipx
        elif command -v sudo >/dev/null 2>&1; then
          sudo dnf install -y pipx
        else
          die "pipx not found; install pipx manually or re-run as root"
        fi
      else
        die "dnf not found; install pipx manually"
      fi
      ;;
    *)
      die "unsupported OS for automatic Ansible install; install ansible-playbook manually or use --skip-install"
      ;;
  esac
}

ensure_ansible() {
  if command -v ansible-playbook >/dev/null 2>&1; then
    return 0
  fi
  if [[ "${SKIP_INSTALL}" == "true" ]]; then
    die "ansible-playbook not found on PATH; install Ansible or omit --skip-install"
  fi
  if ! command -v pipx >/dev/null 2>&1; then
    install_pipx
  fi
  pipx ensurepath
  if ! command -v pipx >/dev/null 2>&1; then
    export PATH="${HOME}/.local/bin:${PATH}"
  fi
  pipx install --include-deps ansible
  if ! command -v ansible-playbook >/dev/null 2>&1; then
    export PATH="${HOME}/.local/bin:${PATH}"
  fi
  command -v ansible-playbook >/dev/null 2>&1 || die "ansible-playbook still not on PATH after pipx install"
}

resolve_path() {
  local path="$1"
  if [[ "${path}" = /* ]]; then
    printf '%s\n' "${path}"
  else
    printf '%s\n' "${SCRIPT_DIR}/${path}"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --inventory)
      [[ $# -ge 2 ]] || die "--inventory requires a path argument"
      INVENTORY="$(resolve_path "$2")"
      shift 2
      ;;
    --playbook)
      [[ $# -ge 2 ]] || die "--playbook requires a name argument"
      PLAYBOOK_NAME="$2"
      shift 2
      ;;
    --limit)
      [[ $# -ge 2 ]] || die "--limit requires a host pattern"
      LIMIT="$2"
      shift 2
      ;;
    --tags)
      [[ $# -ge 2 ]] || die "--tags requires a tag list"
      TAGS="$2"
      shift 2
      ;;
    --check)
      CHECK=true
      shift
      ;;
    --syntax-check)
      SYNTAX_CHECK=true
      shift
      ;;
    --skip-install)
      SKIP_INSTALL=true
      shift
      ;;
    -e|--extra-vars)
      [[ $# -ge 2 ]] || die "-e requires KEY=VALUE"
      EXTRA_VARS+=("$2")
      shift 2
      ;;
    *)
      die "unknown option: $1 (try --help)"
      ;;
  esac
done

require_linux_x86_64
ensure_ansible

PLAYBOOK="$(resolve_path "ansible/playbooks/${PLAYBOOK_NAME}.yml")"
[[ -f "${PLAYBOOK}" ]] || die "playbook not found: ${PLAYBOOK}"

ANSIBLE_ARGS=(
  ansible-playbook
  "${PLAYBOOK}"
  -i "${INVENTORY}"
)

if [[ -n "${LIMIT}" ]]; then
  ANSIBLE_ARGS+=(--limit "${LIMIT}")
fi
if [[ -n "${TAGS}" ]]; then
  ANSIBLE_ARGS+=(--tags "${TAGS}")
fi
if [[ "${CHECK}" == "true" ]]; then
  ANSIBLE_ARGS+=(--check)
fi
if [[ "${SYNTAX_CHECK}" == "true" ]]; then
  ANSIBLE_ARGS+=(--syntax-check)
fi
for ev in "${EXTRA_VARS[@]}"; do
  ANSIBLE_ARGS+=(--extra-vars "${ev}")
done

log "exec: ${ANSIBLE_ARGS[*]}"
exec "${ANSIBLE_ARGS[@]}"
