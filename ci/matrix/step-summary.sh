#!/usr/bin/env bash
# Append a named check result to GITHUB_STEP_SUMMARY.
set -euo pipefail

name="${1:?check name required}"
status="${2:?status required (pass|fail|skip)}"
detail="${3:-}"

case "${status}" in
  pass) icon="✅" ;;
  fail) icon="❌" ;;
  skip) icon="⏭️" ;;
  *)
    echo "unknown status: ${status}" >&2
    exit 2
    ;;
esac

{
  printf '%s **%s** — %s\n' "${icon}" "${name}" "${status}"
  if [[ -n "${detail}" ]]; then
    printf '%s\n' "${detail}"
  fi
  printf '\n'
} >>"${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY required}"
