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
# Root-only file: elevate the read, never the file mode.
read_secret() {
  local file="$1" key="$2" rc=0
  sudo -n true 2>/dev/null || {
    echo "passwordless sudo is required to read root-only ${file}" >&2
    return 1
  }
  sudo test -f "${file}" || {
    echo "secret file missing: ${file}" >&2
    return 1
  }
  sudo grep -E "^${key}=" "${file}" | head -n1 | cut -d= -f2- || rc=$?
  if [[ "${rc}" -gt 1 ]]; then
    echo "secret read failed for ${key} (rc=${rc}): ${file}" >&2
    return 1
  fi
}

SECRET="$(read_secret "${ENV_FILE}" API_GITHUB_WEBHOOK_SECRET)"

if [[ -z "${SECRET}" ]]; then
  echo "synthetic-github-webhook: webhook secret missing (API_GITHUB_WEBHOOK_SECRET)" >&2
  exit 1
fi

PAYLOAD='{"action":"opened","number":1,"pull_request":{"number":1,"head":{"sha":"deadbeef"},"base":{"ref":"main"},"html_url":"https://github.com/example/ci-canary/pull/1"},"repository":{"full_name":"example/ci-canary","name":"ci-canary","owner":{"login":"example"}}}'

SIG="$(printf 'sha256=%s' "$(printf '%s' "${PAYLOAD}" | openssl dgst -sha256 -hmac "${SECRET}" | awk '{print $2}')")"

CODE="$(curl -sk -o /tmp/qops-webhook-body.txt -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -H 'X-GitHub-Event: pull_request' \
  -H "X-Hub-Signature-256: ${SIG}" \
  -X POST -d "${PAYLOAD}" "${WEBHOOK_URL}")"

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
