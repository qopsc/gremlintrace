#!/usr/bin/env bash
# Verify an installed E2B dist tree against its SHA256SUMS and current symlink.
set -euo pipefail

VERSION_DIR="${1:?version install dir required}"
CURRENT_LINK="${2:?current symlink path required}"
ENVD_DEST="${3:?envd destination path required}"
EXPECTED_VERSION="${4:?expected e2b_dist_version required}"

if [[ ! -d "${VERSION_DIR}" ]]; then
  exit 1
fi
if [[ ! -L "${CURRENT_LINK}" ]]; then
  exit 1
fi
resolved="$(readlink -f "${CURRENT_LINK}")"
expected_resolved="$(readlink -f "${VERSION_DIR}")"
if [[ "${resolved}" != "${expected_resolved}" ]]; then
  exit 1
fi
if [[ ! -f "${VERSION_DIR}/SHA256SUMS" ]]; then
  exit 1
fi

(
  cd "${VERSION_DIR}"
  sha256sum -c SHA256SUMS
)

if [[ -f "${VERSION_DIR}/BUILD_INFO" ]]; then
  observed="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("e2b_dist_version",""))' \
    "${VERSION_DIR}/BUILD_INFO")"
  if [[ -n "${observed}" && "${observed}" != "${EXPECTED_VERSION}" ]]; then
    echo "BUILD_INFO e2b_dist_version ${observed} != ${EXPECTED_VERSION}" >&2
    exit 1
  fi
fi

if [[ ! -f "${ENVD_DEST}" ]]; then
  exit 1
fi

echo verified
