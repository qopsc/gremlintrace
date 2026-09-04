#!/usr/bin/env bash
# Verify Firecracker/kernel/busybox artifacts are present and match SHA256SUMS.
set -euo pipefail

ARCHIVE="${1:?archive path required}"
FC_VERSIONS_DIR="${2:?fc versions dir required}"
FC_KERNELS_DIR="${3:?fc kernels dir required}"
FC_BUSYBOX_DIR="${4:?fc busybox dir required}"
FIRECRACKER_VERSION="${5:?firecracker version required}"
KERNEL_VERSION="${6:?kernel version required}"
BUSYBOX_VERSION="${7:?busybox version required}"

STAGE="$(mktemp -d)"
CHECKSUMS="$(mktemp)"
trap 'rm -rf "${STAGE}"; rm -f "${CHECKSUMS}"' EXIT

tar -xzf "${ARCHIVE}" -C "${STAGE}"

expected=(
  "${FC_VERSIONS_DIR}/${FIRECRACKER_VERSION}/amd64/firecracker"
  "${FC_KERNELS_DIR}/${KERNEL_VERSION}/amd64/vmlinux.bin"
  "${FC_BUSYBOX_DIR}/${BUSYBOX_VERSION}/amd64/busybox"
)

for path in "${expected[@]}"; do
  [[ -f "${path}" ]] || exit 1
done

(
  cd "${STAGE}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    sum="${line%%[[:space:]]*}"
    rel="${line#"${sum}"}"
    rel="${rel#"${rel%%[![:space:]]*}"}"
    case "${rel}" in
      firecrackers/*)
        installed="${FC_VERSIONS_DIR}/${rel#firecrackers/}"
        ;;
      kernels/*)
        installed="${FC_KERNELS_DIR}/${rel#kernels/}"
        ;;
      busybox/*)
        installed="${FC_BUSYBOX_DIR}/${rel#busybox/}"
        ;;
      *)
        continue
        ;;
    esac
    printf '%s  %s\n' "${sum}" "${installed}" >>"${CHECKSUMS}"
  done <SHA256SUMS
)

sha256sum -c "${CHECKSUMS}"
