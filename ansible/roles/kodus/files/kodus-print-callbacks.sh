#!/usr/bin/env bash
set -euo pipefail

WEB_URL="${1:?web url required}"
WEBHOOKS_URL="${2:?webhooks url required}"
API_URL="${3:?api url required}"
OUT="${4:-}"

body=$(cat <<EOF
Register these URLs with each Git provider before connecting repositories.

GitHub App
  Homepage URL:     ${WEB_URL}
  Callback URL:     ${WEB_URL}/api/auth/callback/github
  Setup URL:        ${WEB_URL}/setup/github
  Webhook URL:      ${WEBHOOKS_URL}/github/webhook

GitHub OAuth App (optional sign-in)
  Homepage URL:     ${WEB_URL}
  Authorization callback URL: ${WEB_URL}/api/auth/callback/github

GitLab
  Webhook URL:      ${WEBHOOKS_URL}/gitlab/webhook

Bitbucket
  Webhook URL:      ${WEBHOOKS_URL}/bitbucket/webhook

Azure Repos
  Webhook URL:      ${WEBHOOKS_URL}/azure-repos/webhook
  (also accepted:   ${WEBHOOKS_URL}/azdevops/webhook)

Forgejo / Gitea
  Webhook URL:      ${WEBHOOKS_URL}/forgejo/webhook

MCP manager OAuth redirect
  ${WEB_URL}/setup/mcp/oauth

Public API (WEB_HOSTNAME_API)
  ${API_URL}
EOF
)

printf '%s\n' "${body}"
if [[ -n "${OUT}" ]]; then
  umask 077
  mkdir -p "$(dirname "${OUT}")"
  printf '%s\n' "${body}" >"${OUT}"
  chmod 0644 "${OUT}"
fi
