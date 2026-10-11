#!/usr/bin/env bash
# Thin entry point: ensure Ansible is available, then run ansible-playbook.
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
if [[ "${SCRIPT_PATH}" != */* ]]; then
  SCRIPT_PATH="./${SCRIPT_PATH}"
fi
SCRIPT_DIR="$(cd "${SCRIPT_PATH%/*}" && pwd)"
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

# Read one scalar pin from versions.yml without needing python on the control
# machine (the pipx path runs before any Python environment is guaranteed).
pin() {
  local value
  value="$(sed -n "s/^$1:[[:space:]]*\"\{0,1\}\([^\"#]*\)\"\{0,1\}[[:space:]]*\(#.*\)\{0,1\}$/\1/p" "${SCRIPT_DIR}/versions.yml" | head -n1)"
  [[ -n "${value}" ]] || die "versions.yml has no value for $1"
  printf '%s\n' "${value}"
}

log() {
  printf '%s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
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

pipx_bin_dir() {
  local dir=""
  if command -v pipx >/dev/null 2>&1; then
    dir="$(pipx environment --value PIPX_BIN_DIR 2>/dev/null || true)"
  fi
  if [[ -z "${dir}" ]]; then
    dir="${HOME}/.local/bin"
  fi
  printf '%s\n' "${dir}"
}

prepend_pipx_bin_to_path() {
  local bin_dir
  bin_dir="$(pipx_bin_dir)"
  export PATH="${bin_dir}:${PATH}"
}

ensure_ansible() {
  prepend_pipx_bin_to_path
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
  prepend_pipx_bin_to_path
  if command -v ansible-playbook >/dev/null 2>&1; then
    return 0
  fi
  local core_spec
  core_spec="ansible-core==$(pin ansible_core_version)"
  # ansible-core pinned from versions.yml; collections come from ensure_collections.
  if ! pipx install "${core_spec}"; then
    prepend_pipx_bin_to_path
    if command -v ansible-playbook >/dev/null 2>&1; then
      return 0
    fi
    die "pipx install ansible failed and ansible-playbook is still not on PATH"
  fi
  prepend_pipx_bin_to_path
  command -v ansible-playbook >/dev/null 2>&1 || die "ansible-playbook still not on PATH after pipx install"
}

# Collections the roles and ansible.cfg need, pinned in versions.yml. The pipx
# `ansible` package bundles its own versions; an exact-version install into the
# user collection path takes precedence and keeps every run on the pins.
ensure_collections() {
  if ! command -v ansible-galaxy >/dev/null 2>&1; then
    log "warning: ansible-galaxy not on PATH; skipping collection pin check"
    return 0
  fi
  local installed specs=() name key version
  installed="$(ansible-galaxy collection list 2>/dev/null || true)"
  for name in ansible.posix community.general community.sops; do
    key="${name//./_}_version"
    version="$(pin "${key}")"
    if ! printf '%s\n' "${installed}" | awk -v n="${name}" -v v="${version}" '$1 == n && $2 == v { found = 1 } END { exit !found }'; then
      specs+=("${name}:${version}")
    fi
  done
  if [[ "${#specs[@]}" -gt 0 ]]; then
    log "installing pinned collections: ${specs[*]}"
    ansible-galaxy collection install "${specs[@]}"
  fi
}

# Operator secrets are age-encrypted *.sops.yml files under the inventory's
# host_vars/group_vars, decrypted on this machine by community.sops. Fail here
# with a plain message instead of deep inside the vars plugin.
check_sops_prerequisites() {
  local inv_dir encrypted key_default
  inv_dir="$(cd "$(dirname "${INVENTORY}")" && pwd)"
  encrypted="$(find "${inv_dir}/host_vars" "${inv_dir}/group_vars" -type f \
    \( -name '*.sops.yml' -o -name '*.sops.yaml' -o -name '*.sops.json' \) 2>/dev/null | head -n1 || true)"
  [[ -n "${encrypted}" ]] || return 0
  if ! command -v sops >/dev/null 2>&1; then
    die "inventory has encrypted vars (${encrypted}) but sops is not on PATH; install sops and age on this control machine (see docs/install.md)"
  fi
  key_default="${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt"
  if [[ -z "${SOPS_AGE_KEY:-}" && -z "${SOPS_AGE_KEY_CMD:-}" ]] \
    && [[ -z "${SOPS_AGE_KEY_FILE:-}" || ! -f "${SOPS_AGE_KEY_FILE}" ]] \
    && [[ ! -f "${key_default}" ]]; then
    die "inventory has encrypted vars (${encrypted}) but no age private key is configured; set SOPS_AGE_KEY_FILE to your age key (or place it at ${key_default})"
  fi
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

# The Linux x86_64 requirement applies to the managed host (preflight role);
# this control machine only needs ansible-playbook, sops and SSH.
check_sops_prerequisites
ensure_ansible
ensure_collections

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
if [[ "${#EXTRA_VARS[@]}" -gt 0 ]]; then
  for ev in "${EXTRA_VARS[@]}"; do
    ANSIBLE_ARGS+=(--extra-vars "${ev}")
  done
fi

LOG_ARGS=("${ANSIBLE_ARGS[@]}")
for ((i = 0; i < ${#LOG_ARGS[@]}; i++)); do
  if [[ "${LOG_ARGS[$i]}" == "--extra-vars" ]]; then
    i=$((i + 1))
    LOG_ARGS[i]='[REDACTED]'
  fi
done

log "exec: ${LOG_ARGS[*]}"
exec "${ANSIBLE_ARGS[@]}"
