#!/usr/bin/env bash
# Build a minimal e2b-fc-artifacts tarball for verify-fc-artifacts.sh tests.
set -euo pipefail

OUT="${1:?output tar.gz path required}"
FC_VER="${2:-v1.14-0.2.0}"
KERNEL_VER="${3:-vmlinux-test}"
BUSYBOX_VER="${4:-1.36.1}"

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

mkdir -p \
  "${STAGE}/firecrackers/${FC_VER}/amd64" \
  "${STAGE}/kernels/${KERNEL_VER}/amd64" \
  "${STAGE}/busybox/${BUSYBOX_VER}/amd64"

printf 'firecracker-binary\n' >"${STAGE}/firecrackers/${FC_VER}/amd64/firecracker"
printf 'vmlinux-binary\n' >"${STAGE}/kernels/${KERNEL_VER}/amd64/vmlinux.bin"
printf 'busybox-binary\n' >"${STAGE}/busybox/${BUSYBOX_VER}/amd64/busybox"

(
  cd "${STAGE}"
  find firecrackers kernels busybox -type f | LC_ALL=C sort | while IFS= read -r f; do
    sha256sum "${f}"
  done
) >"${STAGE}/SHA256SUMS"

tar -C "${STAGE}" -czf "${OUT}" firecrackers kernels busybox SHA256SUMS
