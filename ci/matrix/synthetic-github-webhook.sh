#!/usr/bin/env bash
# POST a synthetic GitHub pull_request webhook to the local Kodus webhooks endpoint.
#
# Proves:
#   - Traefik routes kodus-webhooks.<domain> to the webhooks container
#   - TLS (provided mode) terminates for the webhook vhost
#   - The webhooks HTTP handler accepts a well-formed signed payload
#
# Does NOT prove:
#   - GitHub can reach the host (no inbound delivery from github.com)
#   - A cloudflared tunnel or customer NAT path works
#   - A canary repository receives events or opens a PR review
#   - Cross-file / graph-stage review comments (needs a real PR + sandbox + LLM)
#   - Webhook delivery latency or retry behaviour from the Git provider
set -euo pipefail

# shellcheck source=/dev/null
source /etc/qops/ci-matrix.env

DOMAIN="${QOPS_CI_DOMAIN}"
WEBHOOK_URL="https://kodus-webhooks.${DOMAIN}/github/webhook"
ENV_FILE="/opt/kodus-installer/.env"
SECRET=""

if [[ -f "${ENV_FILE}" ]]; then
  SECRET="$(grep -E '^API_GITHUB_WEBHOOK_SECRET=' "${ENV_FILE}" | head -n1 | cut -d= -f2- || true)"
fi

PAYLOAD='{"action":"opened","number":1,"pull_request":{"number":1,"head":{"sha":"deadbeef"},"base":{"ref":"main"},"html_url":"https://github.com/example/ci-canary/pull/1"},"repository":{"full_name":"example/ci-canary","name":"ci-canary","owner":{"login":"example"}}}'

SIG=""
if [[ -n "${SECRET}" ]]; then
  SIG="$(printf 'sha256=%s' "$(printf '%s' "${PAYLOAD}" | openssl dgst -sha256 -hmac "${SECRET}" | awk '{print $2}')")"
fi

HEADERS=(-H 'Content-Type: application/json' -H 'X-GitHub-Event: pull_request')
if [[ -n "${SIG}" ]]; then
  HEADERS+=(-H "X-Hub-Signature-256: ${SIG}")
fi

CODE="$(curl -sk -o /tmp/qops-webhook-body.txt -w '%{http_code}' \
  "${HEADERS[@]}" -X POST -d "${PAYLOAD}" "${WEBHOOK_URL}")"

if [[ ! "${CODE}" =~ ^2 ]]; then
  echo "synthetic webhook returned HTTP ${CODE}" >&2
  head -c 500 /tmp/qops-webhook-body.txt >&2 || true
  exit 1
fi

if [[ -n "${QOPS_CI_CANARY_REPO_TOKEN:-}" && -n "${QOPS_CI_CANARY_REPO:-}" ]]; then
  curl -fsS -H "Authorization: Bearer ${QOPS_CI_CANARY_REPO_TOKEN}" \
    "https://api.github.com/repos/${QOPS_CI_CANARY_REPO}" >/dev/null
  printf 'synthetic-webhook: ok (local POST HTTP %s; canary token can read %s)\n' "${CODE}" "${QOPS_CI_CANARY_REPO}"
else
  printf 'synthetic-webhook: ok (local POST HTTP %s; canary repo not configured)\n' "${CODE}"
fi
