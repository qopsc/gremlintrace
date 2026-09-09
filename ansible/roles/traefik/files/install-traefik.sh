#!/usr/bin/env bash
# Install the Traefik static binary after verifying the release checksums file.
set -euo pipefail

VERSION="${1:?traefik_version required}"
DEST="${2:?destination binary path required}"
ARCHIVE="${3:?archive path required}"
CHECKSUMS="${4:?checksums file required}"

if [[ ! -f "${ARCHIVE}" ]]; then
  echo "traefik archive missing: ${ARCHIVE}" >&2
  exit 1
fi
if [[ ! -f "${CHECKSUMS}" ]]; then
  echo "traefik checksums missing: ${CHECKSUMS}" >&2
  exit 1
fi

archive_name="$(basename "${ARCHIVE}")"
expected="$(awk -v name="${archive_name}" '$2 == name { print $1; found=1 } END { if (!found) exit 1 }' "${CHECKSUMS}")"
observed="$(sha256sum "${ARCHIVE}" | awk '{print $1}')"
if [[ "${expected}" != "${observed}" ]]; then
  echo "traefik checksum mismatch for ${archive_name}" >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
tar -xzf "${ARCHIVE}" -C "${STAGE}"
if [[ ! -f "${STAGE}/traefik" ]]; then
  echo "traefik binary missing from archive" >&2
  exit 1
fi

mkdir -p "$(dirname "${DEST}")"
install -m 0755 "${STAGE}/traefik" "${DEST}"
echo "installed ${VERSION}"
