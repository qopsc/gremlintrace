#!/usr/bin/env bash
# Confirm the installed Traefik binary reports a parsed, non-empty version
# that exactly matches traefik_version. An executable that exits 0 without a
# recognisable version must not skip install.
set -euo pipefail

DEST="${1:?destination binary path required}"
VERSION="${2:?traefik_version required}"

if [[ ! -x "${DEST}" ]]; then
  exit 1
fi

reported="$("${DEST}" version 2>/dev/null | awk '/^Version:/{print $2; exit}')"
if [[ -z "${reported}" ]]; then
  reported="$("${DEST}" version 2>/dev/null | awk '/^version[[:space:]]/{print $2; exit}')"
fi
want="${VERSION#v}"
got="${reported#v}"
if [[ -z "${got}" || "${got}" != "${want}" ]]; then
  echo "traefik reports ${reported:-<empty>}, expected ${VERSION}" >&2
  exit 1
fi
echo verified
