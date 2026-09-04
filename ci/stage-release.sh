#!/usr/bin/env bash
# Stage GitHub Release assets (dist tarball + packed mirrored-artifacts tarball).
set -euo pipefail
export LC_ALL=C

usage() {
  cat <<'EOF'
Usage: stage-release.sh --dist-tarball PATH --mirrored-tarball PATH --upload-dir DIR
EOF
}

DIST_TARBALL=""
MIRRORED_TARBALL=""
UPLOAD_DIR=""

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dist-tarball)
      DIST_TARBALL="${2:?}"
      shift 2
      ;;
    --mirrored-tarball)
      MIRRORED_TARBALL="${2:?}"
      shift 2
      ;;
    --upload-dir)
      UPLOAD_DIR="${2:?}"
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

[[ -f "${DIST_TARBALL}" ]] || die "missing dist tarball: ${DIST_TARBALL}"
[[ -f "${MIRRORED_TARBALL}" ]] || die "missing mirrored tarball: ${MIRRORED_TARBALL}"
[[ -f "${MIRRORED_TARBALL}.sha256" ]] || die "missing mirrored tarball checksum: ${MIRRORED_TARBALL}.sha256"
[[ -n "${UPLOAD_DIR}" ]] || die "--upload-dir is required"

rm -rf "${UPLOAD_DIR}"
mkdir -p "${UPLOAD_DIR}"
cp "${DIST_TARBALL}" "${UPLOAD_DIR}/"
cp "${MIRRORED_TARBALL}" "${UPLOAD_DIR}/"
cp "${MIRRORED_TARBALL}.sha256" "${UPLOAD_DIR}/"
(
  cd "${UPLOAD_DIR}"
  sha256sum "$(basename "${DIST_TARBALL}")"
) >"${UPLOAD_DIR}/$(basename "${DIST_TARBALL}").sha256"

printf 'stage-release: ok -> %s\n' "${UPLOAD_DIR}"
ls -1 "${UPLOAD_DIR}"
