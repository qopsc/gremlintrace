#!/usr/bin/env bash
# Mirror Firecracker, kernel, and busybox from E2B's public bucket into our layout.
set -euo pipefail
export LC_ALL=C

usage() {
  cat <<'EOF'
Usage: mirror-e2b-artifacts.sh [--versions FILE] [--out DIR]

Downloads upstream artifacts into <out>/<kind>/<ver>/amd64/<file>, verifies every
binary against the SHA-256 pins in versions.yml (and busybox against its published
.sha256), and writes artifacts-SHA256SUMS for Ansible.
EOF
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS_FILE="${REPO_ROOT}/versions.yml"
OUT_DIR="${REPO_ROOT}/artifacts"
BASE_URL="https://storage.googleapis.com/e2b-artifact-binaries"
STAGE_DIR=""

yaml_get() {
  python3 "${REPO_ROOT}/ci/yaml_versions.py" get "$1" "${VERSIONS_FILE}"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${STAGE_DIR}" && -d "${STAGE_DIR}" ]]; then
    rm -rf "${STAGE_DIR}"
  fi
}

fetch() {
  local url="$1"
  local dest="$2"
  local tmp="${dest}.partial"
  local code
  code="$(curl -fsSL -o "${tmp}" -w '%{http_code}' "${url}" || true)"
  if [[ "${code}" != "200" ]]; then
    rm -f "${tmp}"
    die "download failed (${code}): ${url}"
  fi
  mv "${tmp}" "${dest}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --versions)
      VERSIONS_FILE="${2:?}"
      shift 2
      ;;
    --out)
      OUT_DIR="${2:?}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

trap cleanup EXIT

FC_VER="$(yaml_get firecracker_version)"
KERNEL_VER="$(yaml_get kernel_version)"
BUSYBOX_VER="$(yaml_get busybox_version)"
FC_SHA256="$(yaml_get firecracker_sha256)"
KERNEL_SHA256="$(yaml_get kernel_sha256)"
BUSYBOX_SHA256="$(yaml_get busybox_sha256)"

for pin in "${FC_SHA256}" "${KERNEL_SHA256}" "${BUSYBOX_SHA256}"; do
  [[ "${pin}" =~ ^[0-9a-f]{64}$ ]] || die "invalid artifact SHA-256 pin: ${pin}"
done

OUT_PARENT="$(dirname "${OUT_DIR}")"
mkdir -p "${OUT_PARENT}"
STAGE_DIR="$(mktemp -d "${OUT_DIR}.partial.XXXXXX")"
trap cleanup EXIT

FC_DIR="${STAGE_DIR}/firecrackers/${FC_VER}/amd64"
KERNEL_DIR="${STAGE_DIR}/kernels/${KERNEL_VER}/amd64"
BUSYBOX_DIR="${STAGE_DIR}/busybox/${BUSYBOX_VER}/amd64"

mkdir -p "${FC_DIR}" "${KERNEL_DIR}" "${BUSYBOX_DIR}"

FC_PATH="${FC_DIR}/firecracker"
KERNEL_PATH="${KERNEL_DIR}/vmlinux.bin"
BUSYBOX_PATH="${BUSYBOX_DIR}/busybox"
BUSYBOX_SHA_PATH="${BUSYBOX_DIR}/busybox.sha256"

fetch "${BASE_URL}/firecrackers/${FC_VER}/amd64/firecracker" "${FC_PATH}"
fetch "${BASE_URL}/kernels/${KERNEL_VER}/amd64/vmlinux.bin" "${KERNEL_PATH}"
fetch "${BASE_URL}/busybox/${BUSYBOX_VER}/amd64/busybox" "${BUSYBOX_PATH}"
fetch "${BASE_URL}/busybox/${BUSYBOX_VER}/amd64/busybox.sha256" "${BUSYBOX_SHA_PATH}"

chmod 0755 "${FC_PATH}" "${KERNEL_PATH}" "${BUSYBOX_PATH}"

verify_sha256() {
  local path="$1"
  local expected="$2"
  local label="$3"
  local actual
  actual="$(sha256sum "${path}" | awk '{print $1}')"
  [[ "${actual}" == "${expected}" ]] || die "${label} checksum mismatch: expected ${expected}, got ${actual}"
}

verify_sha256 "${FC_PATH}" "${FC_SHA256}" "firecracker/${FC_VER}"
verify_sha256 "${KERNEL_PATH}" "${KERNEL_SHA256}" "kernel/${KERNEL_VER}"

(
  cd "${BUSYBOX_DIR}"
  sha256sum -c busybox.sha256
)
verify_sha256 "${BUSYBOX_PATH}" "${BUSYBOX_SHA256}" "busybox/${BUSYBOX_VER}"

MANIFEST="${STAGE_DIR}/artifacts-SHA256SUMS"
{
  printf '%s  %s\n' "${FC_SHA256}" "firecrackers/${FC_VER}/amd64/firecracker"
  printf '%s  %s\n' "${KERNEL_SHA256}" "kernels/${KERNEL_VER}/amd64/vmlinux.bin"
  printf '%s  %s\n' "${BUSYBOX_SHA256}" "busybox/${BUSYBOX_VER}/amd64/busybox"
} >"${MANIFEST}"

(
  cd "${STAGE_DIR}"
  sha256sum -c artifacts-SHA256SUMS
)

mkdir -p "${OUT_DIR}"
cp -a "${STAGE_DIR}/firecrackers" "${OUT_DIR}/"
cp -a "${STAGE_DIR}/kernels" "${OUT_DIR}/"
cp -a "${STAGE_DIR}/busybox" "${OUT_DIR}/"
cp "${MANIFEST}" "${OUT_DIR}/artifacts-SHA256SUMS"

printf 'mirror-e2b-artifacts: ok -> %s\n' "${OUT_DIR}"
