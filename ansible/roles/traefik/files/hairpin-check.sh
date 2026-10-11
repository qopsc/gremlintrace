#!/usr/bin/env bash
# Probe https://api.e2b.<domain>/health from a container on the Kodus network.
#
# Ordering: the traefik role runs BEFORE kodus creates the `kodus` Docker
# network. During that first-install pass TRAEFIK_HAIRPIN_REQUIRED is unset
# (or 0): a missing network prints `skipped` and does not fail.
# site.yml re-invokes this script after the kodus role (and doctor.yml does
# the same) with TRAEFIK_HAIRPIN_REQUIRED=1. That is the real gate: it
# retries for TLS readiness and requires HTTP 200. Nonempty output without
# a 200 is a failure.
set -euo pipefail

NETWORK="${1:?docker network name required}"
URL="${2:?health url required}"
IMAGE="${3:?probe image required}"
DOCKER_BIN="${4:-docker}"
REQUIRED="${TRAEFIK_HAIRPIN_REQUIRED:-0}"
RETRIES="${TRAEFIK_HAIRPIN_RETRIES:-30}"
DELAY="${TRAEFIK_HAIRPIN_DELAY:-2}"
# Space-separated "name:host-gateway" entries (kodus_extra_hosts_hairpin) and an
# optional CA file for provided/internal_ca certificates the probe image does
# not trust. Both are forwarded into the probe container.
EXTRA_HOSTS="${TRAEFIK_HAIRPIN_EXTRA_HOSTS:-}"
CA_FILE="${TRAEFIK_HAIRPIN_CA_FILE:-}"

if ! [[ "${RETRIES}" =~ ^[0-9]+$ && "${DELAY}" =~ ^[0-9]+$ ]]; then
  echo "hairpin retries and delay must be integers" >&2
  exit 1
fi

skip_or_fail() {
  local message="$1"
  if [[ "${REQUIRED}" == "1" ]]; then
    echo "${message}" >&2
    exit 1
  fi
  echo "${message}" >&2
  echo skipped
  exit 0
}

if ! command -v "${DOCKER_BIN}" >/dev/null 2>&1; then
  skip_or_fail "docker is not available for the hairpin check"
fi

if ! "${DOCKER_BIN}" network inspect "${NETWORK}" >/dev/null 2>&1; then
  skip_or_fail "docker network ${NETWORK} is absent; hairpin check runs after the kodus role creates it"
fi

run_args=(run --rm --network "${NETWORK}" --entrypoint wget)
wget_args=(-q -S -O- --timeout=15)
for entry in ${EXTRA_HOSTS}; do
  run_args+=(--add-host "${entry}")
done
if [[ -n "${CA_FILE}" ]]; then
  run_args+=(-v "${CA_FILE}:/qops-hairpin-ca.pem:ro")
  wget_args+=(--ca-certificate=/qops-hairpin-ca.pem)
fi

attempt=0
last_out=""
while [[ "${attempt}" -lt "${RETRIES}" ]]; do
  set +e
  last_out="$("${DOCKER_BIN}" "${run_args[@]}" "${IMAGE}" "${wget_args[@]}" "${URL}" 2>&1)"
  rc=$?
  set -e
  if [[ "${rc}" -eq 0 ]] && printf '%s\n' "${last_out}" | grep -Eq 'HTTP/[0-9.]+[[:space:]]+200'; then
    echo ready
    exit 0
  fi
  attempt=$((attempt + 1))
  if [[ "${attempt}" -lt "${RETRIES}" ]]; then
    sleep "${DELAY}"
  fi
done

echo "hairpin check did not observe HTTP 200 from ${URL} on network ${NETWORK}" >&2
printf '%s\n' "${last_out}" >&2
if [[ "${REQUIRED}" != "1" ]]; then
  echo "first-install pass: not a gate; the required hairpin check runs in site.yml after the kodus role" >&2
  echo skipped
  exit 0
fi
if [[ -n "${EXTRA_HOSTS}" ]]; then
  echo "extra_hosts (${EXTRA_HOSTS}) were already applied, so hairpin NAT is not the cause: check DNS for the host, Traefik (systemctl status traefik), the certificate for ${URL}, and nftables input on 443." >&2
else
  echo "If this host cannot reach its own public IP (hairpin NAT), set kodus_extra_hosts_hairpin=true: Kodus containers get extra_hosts to host-gateway for api.e2b/sandbox.e2b/kodus/kodus-api/kodus-webhooks and .env sets E2B_API_URL=https://api.e2b.<domain> and E2B_SANDBOX_URL=https://sandbox.e2b.<domain>; then re-run site.yml." >&2
fi
exit 1
