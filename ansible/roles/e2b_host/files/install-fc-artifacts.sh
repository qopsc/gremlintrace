#!/usr/bin/env bash
# Install mirrored Firecracker/kernel/busybox artifacts into /fc-* layout.
set -euo pipefail

ARCHIVE="${1:?archive path required}"
FC_VERSIONS_DIR="${2:?fc versions dir required}"
FC_KERNELS_DIR="${3:?fc kernels dir required}"
FC_BUSYBOX_DIR="${4:?fc busybox dir required}"
FIRECRACKER_VERSION="${5:?firecracker version required}"
KERNEL_VERSION="${6:?kernel version required}"
BUSYBOX_VERSION="${7:?busybox version required}"

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

tar -xzf "${ARCHIVE}" -C "${STAGE}"
(
  cd "${STAGE}"
  sha256sum -c SHA256SUMS
)

install_tree() {
  local src="$1" dest="$2"
  mkdir -p "${dest}"
  rm -rf "${dest:?}/"*
  cp -a "${src}/." "${dest}/"
}

install_tree "${STAGE}/firecrackers/${FIRECRACKER_VERSION}/amd64" \
  "${FC_VERSIONS_DIR}/${FIRECRACKER_VERSION}/amd64"
install_tree "${STAGE}/kernels/${KERNEL_VERSION}/amd64" \
  "${FC_KERNELS_DIR}/${KERNEL_VERSION}/amd64"
install_tree "${STAGE}/busybox/${BUSYBOX_VERSION}/amd64" \
  "${FC_BUSYBOX_DIR}/${BUSYBOX_VERSION}/amd64"

chmod -R 755 "${FC_VERSIONS_DIR}" "${FC_KERNELS_DIR}" "${FC_BUSYBOX_DIR}"
