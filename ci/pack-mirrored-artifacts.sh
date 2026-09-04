#!/usr/bin/env bash
# Pack a mirrored artifact tree into a release tarball that preserves fc/config.go layout.
set -euo pipefail
export LC_ALL=C

usage() {
  cat <<'EOF'
Usage: pack-mirrored-artifacts.sh --artifacts DIR --out FILE [--versions FILE]

Creates OUT containing firecrackers/, kernels/, busybox/ and SHA256SUMS (paths inside
the tarball are relative to its root). Writes OUT.sha256 alongside OUT.
EOF
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS_FILE="${REPO_ROOT}/versions.yml"
ARTIFACTS_DIR=""
OUT_FILE=""

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

yaml_get() {
  python3 "${REPO_ROOT}/ci/yaml_versions.py" get "$1" "${VERSIONS_FILE}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifacts)
      ARTIFACTS_DIR="${2:?}"
      shift 2
      ;;
    --out)
      OUT_FILE="${2:?}"
      shift 2
      ;;
    --versions)
      VERSIONS_FILE="${2:?}"
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

[[ -n "${ARTIFACTS_DIR}" && -d "${ARTIFACTS_DIR}" ]] || die "--artifacts DIR is required"
[[ -n "${OUT_FILE}" ]] || die "--out FILE is required"

fc_ver="$(yaml_get firecracker_version)"
kernel_ver="$(yaml_get kernel_version)"
busybox_ver="$(yaml_get busybox_version)"

for path in \
  "firecrackers/${fc_ver}/amd64/firecracker" \
  "kernels/${kernel_ver}/amd64/vmlinux.bin" \
  "busybox/${busybox_ver}/amd64/busybox" \
  "busybox/${busybox_ver}/amd64/busybox.sha256"; do
  [[ -f "${ARTIFACTS_DIR}/${path}" ]] || die "missing mirrored file: ${path}"
done

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/e2b-pack-mirror.XXXXXX")"
trap 'rm -rf "${STAGE}"' EXIT

cp -a "${ARTIFACTS_DIR}/firecrackers" "${STAGE}/"
cp -a "${ARTIFACTS_DIR}/kernels" "${STAGE}/"
cp -a "${ARTIFACTS_DIR}/busybox" "${STAGE}/"

(
  cd "${STAGE}"
  find firecrackers kernels busybox -type f | LC_ALL=C sort | while IFS= read -r f; do
    sha256sum "${f}"
  done
) >"${STAGE}/SHA256SUMS"

(
  cd "${STAGE}"
  sha256sum -c SHA256SUMS
)

mkdir -p "$(dirname "${OUT_FILE}")"
tar -C "${STAGE}" -czf "${OUT_FILE}" firecrackers kernels busybox SHA256SUMS
(
  cd "$(dirname "${OUT_FILE}")"
  sha256sum "$(basename "${OUT_FILE}")"
) >"${OUT_FILE}.sha256"

printf 'pack-mirrored-artifacts: ok -> %s\n' "${OUT_FILE}"
