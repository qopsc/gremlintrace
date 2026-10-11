#!/usr/bin/env bash
# Fail when provided-TLS certificate or key is missing or unreadable.
# Optional third argument is the Traefik username ("-" or empty: skip); when
# set, both files must be readable as that user (sudo -u). Optional fourth
# argument is a comma-separated list of hostnames the certificate must cover
# (a one-level wildcard *.<d> does not cover *.e2b.<d>).
set -euo pipefail

CERT="${1:?certificate path required}"
KEY="${2:?private key path required}"
TRAFFIK_USER="${3:-}"
HOSTNAMES="${4:-}"
[[ "${TRAFFIK_USER}" == "-" ]] && TRAFFIK_USER=""

if [[ -z "${CERT}" || -z "${KEY}" ]]; then
  echo "tls_mode=provided requires tls_cert_path and tls_key_path" >&2
  exit 1
fi

for path in "${CERT}" "${KEY}"; do
  if [[ ! -e "${path}" ]]; then
    echo "provided TLS file missing: ${path}" >&2
    exit 1
  fi
  if [[ ! -f "${path}" ]]; then
    echo "provided TLS path is not a regular file: ${path}" >&2
    exit 1
  fi
  if [[ ! -r "${path}" ]]; then
    echo "provided TLS file is not readable: ${path}" >&2
    exit 1
  fi
done

if [[ -n "${TRAFFIK_USER}" ]]; then
  if ! sudo -u "${TRAFFIK_USER}" test -r "${CERT}" || ! sudo -u "${TRAFFIK_USER}" test -r "${KEY}"; then
    echo "provided TLS files are not readable as ${TRAFFIK_USER}" >&2
    exit 1
  fi
fi

if [[ -n "${HOSTNAMES}" ]]; then
  uncovered=()
  IFS=',' read -r -a names <<<"${HOSTNAMES}"
  for name in "${names[@]}"; do
    name="${name// /}"
    [[ -n "${name}" ]] || continue
    if ! openssl x509 -in "${CERT}" -noout -checkhost "${name}" 2>/dev/null | grep -q 'does match'; then
      uncovered+=("${name}")
    fi
  done
  if (( ${#uncovered[@]} > 0 )); then
    echo "provided certificate ${CERT} does not cover: ${uncovered[*]} (needs SANs for kodus, kodus-api, kodus-webhooks, api.e2b and *.e2b under the domain)" >&2
    exit 1
  fi
fi

echo ok
