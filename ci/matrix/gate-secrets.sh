#!/usr/bin/env bash
# Decide whether the installer matrix leg may run (secrets present, trusted ref).
set -euo pipefail

skip_reason=""

if [[ "${GITHUB_EVENT_NAME:-}" == "pull_request" ]]; then
  head_repo="${GITHUB_HEAD_REPOSITORY:-}"
  base_repo="${GITHUB_REPOSITORY:-}"
  if [[ -n "${head_repo}" && -n "${base_repo}" && "${head_repo}" != "${base_repo}" ]]; then
    skip_reason="Fork pull requests cannot access repository secrets; installer matrix skipped."
  fi
fi

if [[ -z "${skip_reason}" ]]; then
  if [[ -z "${QOPS_CI_LLM_API_KEY:-}" ]]; then
    skip_reason="QOPS_CI_LLM_API_KEY is not configured; installer matrix skipped."
  elif [[ -z "${QOPS_CI_CANARY_REPO_TOKEN:-}" ]]; then
    skip_reason="QOPS_CI_CANARY_REPO_TOKEN is not configured; installer matrix skipped."
  elif [[ -z "${QOPS_CI_WEBHOOK_EXTERNAL_PROBE_CMD:-}" ]]; then
    skip_reason="QOPS_CI_WEBHOOK_EXTERNAL_PROBE_CMD is not configured; installer matrix skipped."
  fi
fi

if [[ -n "${skip_reason}" ]]; then
  echo "run_install=false" >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT required}"
  echo "skip_reason=${skip_reason}" >>"${GITHUB_OUTPUT}"
  printf 'skip: %s\n' "${skip_reason}" >&2
  exit 0
fi

echo "run_install=true" >>"${GITHUB_OUTPUT}"
echo "skip_reason=" >>"${GITHUB_OUTPUT}"
printf 'gate: secrets present; installer matrix will run\n'
