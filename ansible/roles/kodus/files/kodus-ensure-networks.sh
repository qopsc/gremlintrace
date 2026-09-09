#!/usr/bin/env bash
set -euo pipefail

DOCKER_BIN="${DOCKER_BIN:-docker}"
if ! command -v "${DOCKER_BIN}" >/dev/null 2>&1; then
  echo "docker is required to create Kodus networks" >&2
  exit 1
fi

created=0
for net in "$@"; do
  if "${DOCKER_BIN}" network inspect "${net}" >/dev/null 2>&1; then
    echo "exists ${net}"
    continue
  fi
  "${DOCKER_BIN}" network create "${net}" >/dev/null
  echo "created ${net}"
  created=1
done

if [[ "${created}" -eq 1 ]]; then
  echo changed
else
  echo unchanged
fi
