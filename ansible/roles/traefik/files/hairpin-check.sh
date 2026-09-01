#!/usr/bin/env bash
# Probe https://api.e2b.<domain>/health from a container on the Kodus network.
# The Kodus network does not exist until the kodus role (site.yml after traefik).
set -euo pipefail

NETWORK="${1:?docker network name required}"
URL="${2:?health url required}"
IMAGE="${3:?probe image required}"
DOCKER_BIN="${4:-docker}"

if ! command -v "${DOCKER_BIN}" >/dev/null 2>&1; then
  echo "skipped: docker is not available for the hairpin check" >&2
  echo skipped
  exit 0
fi

if ! "${DOCKER_BIN}" network inspect "${NETWORK}" >/dev/null 2>&1; then
  echo "skipped: docker network ${NETWORK} is absent; hairpin check runs after the kodus role creates it" >&2
  echo skipped
  exit 0
fi

set +e
out="$("${DOCKER_BIN}" run --rm --network "${NETWORK}" --entrypoint wget \
  "${IMAGE}" -q -S -O- --timeout=15 "${URL}" 2>&1)"
rc=$?
set -e
if [[ "${rc}" -ne 0 ]]; then
  echo "hairpin check failed for ${URL} on network ${NETWORK}" >&2
  printf '%s\n' "${out}" >&2
  exit 1
fi
if ! printf '%s\n' "${out}" | grep -Eq 'HTTP/[^ ]+ 200'; then
  if [[ -n "${out}" ]]; then
    echo ready
    exit 0
  fi
  echo "hairpin check did not observe HTTP 200 from ${URL}" >&2
  exit 1
fi
echo ready
