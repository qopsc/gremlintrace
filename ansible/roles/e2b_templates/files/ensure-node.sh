#!/usr/bin/env bash
# Use host node when the major version matches versions.yml; otherwise fail.
set -euo pipefail

REQUIRED_MAJOR="${1:?node major version required}"
NODE_BIN="${2:-node}"

if ! command -v "${NODE_BIN}" >/dev/null 2>&1; then
  echo "node is not installed on PATH (${NODE_BIN}); install Node ${REQUIRED_MAJOR}" >&2
  exit 1
fi

version="$("${NODE_BIN}" -v)"
version="${version#v}"
major="${version%%.*}"
if [[ "${major}" != "${REQUIRED_MAJOR}" ]]; then
  echo "node ${version} does not match required major ${REQUIRED_MAJOR}" >&2
  exit 1
fi
echo "${version}"
