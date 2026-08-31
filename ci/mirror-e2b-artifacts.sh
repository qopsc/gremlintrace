#!/usr/bin/env bash
# Mirror Firecracker, kernel, and busybox from E2B's public bucket into our layout.
set -euo pipefail
export LC_ALL=C

usage() {
  cat <<'EOF'
Usage: mirror-e2b-artifacts.sh [--versions FILE] [--out DIR]

Downloads upstream artifacts into <out>/<kind>/<ver>/amd64/<file>, verifies busybox
against the published .sha256, and writes artifacts-SHA256SUMS for Ansible.
EOF
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS_FILE="${REPO_ROOT}/versions.yml"
OUT_DIR="${REPO_ROOT}/artifacts"
BASE_URL="https://storage.googleapis.com/e2b-artifact-binaries"

yaml_get() {
  local file="$1"
  local key="$2"
  python3 -c '
import sys
import yaml

path, key = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    data = yaml.safe_load(fh)
print(data[key])
' "${file}" "${key}"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
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

FC_VER="$(yaml_get "${VERSIONS_FILE}" firecracker_version)"
KERNEL_VER="$(yaml_get "${VERSIONS_FILE}" kernel_version)"
BUSYBOX_VER="$(yaml_get "${VERSIONS_FILE}" busybox_version)"

FC_DIR="${OUT_DIR}/firecrackers/${FC_VER}/amd64"
KERNEL_DIR="${OUT_DIR}/kernels/${KERNEL_VER}/amd64"
BUSYBOX_DIR="${OUT_DIR}/busybox/${BUSYBOX_VER}/amd64"

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

(
  cd "${BUSYBOX_DIR}"
  sha256sum -c busybox.sha256
)

MANIFEST="${OUT_DIR}/artifacts-SHA256SUMS"
{
  (cd "${OUT_DIR}" && sha256sum "firecrackers/${FC_VER}/amd64/firecracker")
  (cd "${OUT_DIR}" && sha256sum "kernels/${KERNEL_VER}/amd64/vmlinux.bin")
  (cd "${OUT_DIR}" && sha256sum "busybox/${BUSYBOX_VER}/amd64/busybox")
} >"${MANIFEST}"

(
  cd "${OUT_DIR}"
  sha256sum -c artifacts-SHA256SUMS
)

printf 'mirror-e2b-artifacts: ok -> %s\n' "${OUT_DIR}"
