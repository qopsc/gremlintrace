#!/usr/bin/env bash
# Render an Ansible role template to stdout for offline tests.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATE_REL="${1:?template path relative to repo root}"
VARS_FILE="${2:-${REPO_ROOT}/tests/fixtures/ansible-role-vars.yml}"
EXTRA_VARS="${3:-}"

export ANSIBLE_CONFIG="${REPO_ROOT}/ansible.cfg"
export ANSIBLE_ROLES_PATH="${REPO_ROOT}/ansible/roles"
# Template rendering is controller-local and must not require a sudo password.
export ANSIBLE_BECOME=false

dest="$(mktemp)"
cleanup() {
  rm -f "${dest}"
}
trap cleanup EXIT

cmd=(ansible localhost -m ansible.builtin.template -c local)
cmd+=(-a "src=${REPO_ROOT}/${TEMPLATE_REL} dest=${dest}")
cmd+=(-e "@${VARS_FILE}")

if [[ -n "${EXTRA_VARS}" ]]; then
  cmd+=(-e "${EXTRA_VARS}")
fi

"${cmd[@]}" >/dev/null
cat "${dest}"
