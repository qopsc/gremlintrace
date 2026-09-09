#!/usr/bin/env bash
# Verify an installed E2B dist tree against its SHA256SUMS and current symlink.
set -euo pipefail

VERSION_DIR="${1:?version install dir required}"
CURRENT_LINK="${2:?current symlink path required}"
ENVD_DEST="${3:?envd destination path required}"
EXPECTED_VERSION="${4:?expected e2b_dist_version required}"
EXPECTED_PATCH_NAME="${5:-}"
EXPECTED_PATCH_SHA256="${6:-}"

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

if [[ -n "${EXPECTED_PATCH_NAME}" ]]; then
  [[ -n "${EXPECTED_PATCH_SHA256}" ]] || {
    echo "expected patch checksum is required when a patch is required" >&2
    exit 1
  }
  PATCH_CHECKER="/usr/local/lib/qops/e2b-verify-build-patches.py"
  if [[ ! -f "${PATCH_CHECKER}" ]]; then
    PATCH_CHECKER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/e2b-verify-build-patches.py"
  fi
  python3 "${PATCH_CHECKER}" \
    "${VERSION_DIR}/BUILD_INFO" "${EXPECTED_PATCH_NAME}" "${EXPECTED_PATCH_SHA256}"
fi

if [[ ! -f "${ENVD_DEST}" ]]; then
  exit 1
fi

echo verified
