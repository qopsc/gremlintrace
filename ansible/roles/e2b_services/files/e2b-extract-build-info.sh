#!/usr/bin/env bash
# Write BUILD_INFO from an E2B dist tarball to DEST (0600).
set -euo pipefail

ARCHIVE="${1:?dist archive required}"
DEST="${2:?destination path required}"

if [[ ! -f "${ARCHIVE}" ]]; then
  echo "dist archive missing: ${ARCHIVE}" >&2
  exit 1
fi

mkdir -p "$(dirname "${DEST}")"
tmp="$(mktemp "${DEST}.XXXXXX")"
chmod 0600 "${tmp}"
if ! tar -xOf "${ARCHIVE}" BUILD_INFO >"${tmp}"; then
  rm -f "${tmp}"
  echo "BUILD_INFO missing from dist archive ${ARCHIVE}" >&2
  exit 1
fi
if [[ ! -s "${tmp}" ]]; then
  rm -f "${tmp}"
  echo "BUILD_INFO extracted empty from ${ARCHIVE}" >&2
  exit 1
fi
python3 - "${tmp}" <<'PY'
import json
import sys

json.load(open(sys.argv[1], encoding="utf-8"))
PY
mv -f "${tmp}" "${DEST}"
chmod 0600 "${DEST}"
echo "${DEST}"
