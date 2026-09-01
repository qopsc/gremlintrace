#!/usr/bin/env bash
# Run site.yml against localhost with CI inventory and group_vars overrides.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=/dev/null
source /etc/qops/ci-matrix.env

EXTRA=(
  -e "qops_domain=${QOPS_CI_DOMAIN}"
  -e "qops_public_ipv4=${QOPS_CI_PUBLIC_IPV4}"
  -e "qops_lan_ipv4=${QOPS_CI_LAN_IPV4}"
  -e "tls_cert_path=/etc/qops/ci-tls/tls.crt"
  -e "tls_key_path=/etc/qops/ci-tls/tls.key"
)

if [[ -n "${QOPS_CI_LLM_API_KEY:-}" ]]; then
  EXTRA+=(-e "kodus_openai_api_key=${QOPS_CI_LLM_API_KEY}")
fi

exec ./bootstrap.sh \
  --inventory ci/matrix/inventory-localhost.yml \
  --extra-vars "@ci/matrix/group_vars/codereviewer.yml" \
  "${EXTRA[@]}" \
  "$@"
