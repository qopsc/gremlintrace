#!/usr/bin/env bash
# Install an E2B dist tarball after verifying SHA256SUMS.
set -euo pipefail

ARCHIVE="${1:?archive path required}"
VERSION_DIR="${2:?version install dir required}"
CURRENT_LINK="${3:?current symlink path required}"
ENVD_DEST="${4:?envd destination path required}"
EXPECTED_VERSION="${5:?expected e2b_dist_version required}"
EXPECTED_PATCH_NAME="${6:-}"
EXPECTED_PATCH_SHA256="${7:-}"

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

tar -xzf "${ARCHIVE}" -C "${STAGE}"

if [[ ! -f "${STAGE}/SHA256SUMS" ]]; then
  echo "SHA256SUMS missing from dist archive" >&2
  exit 1
fi

(
  cd "${STAGE}"
  sha256sum -c SHA256SUMS
)

if [[ -f "${STAGE}/BUILD_INFO" ]]; then
  observed="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("e2b_dist_version",""))' \
    "${STAGE}/BUILD_INFO")"
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
    "${STAGE}/BUILD_INFO" "${EXPECTED_PATCH_NAME}" "${EXPECTED_PATCH_SHA256}"
fi

required_bins=(orchestrator api client-proxy envd e2b-seed goose)
for bin in "${required_bins[@]}"; do
  if [[ ! -x "${STAGE}/bin/${bin}" && ! -f "${STAGE}/bin/${bin}" ]]; then
    echo "missing dist binary: bin/${bin}" >&2
    exit 1
  fi
done

mkdir -p "${VERSION_DIR}"
rm -rf "${VERSION_DIR:?}/"*
cp -a "${STAGE}/." "${VERSION_DIR}/"
chmod -R a+rX "${VERSION_DIR}"
chmod 755 "${VERSION_DIR}/bin/"*

mkdir -p "$(dirname "${CURRENT_LINK}")"
ln -sfn "${VERSION_DIR}" "${CURRENT_LINK}"

mkdir -p "$(dirname "${ENVD_DEST}")"
cp -a "${VERSION_DIR}/bin/envd" "${ENVD_DEST}"
chmod 755 "${ENVD_DEST}"

echo installed
