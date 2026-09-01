#!/usr/bin/env bash
# Fail when provided-TLS certificate or key is missing or unreadable.
# Optional fourth argument is the Traefik username; when set, both files
# must be readable as that user (sudo -u).
set -euo pipefail

CERT="${1:?certificate path required}"
KEY="${2:?private key path required}"
TRAFFIK_USER="${3:-}"

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

echo ok
