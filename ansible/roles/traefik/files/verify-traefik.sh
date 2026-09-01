#!/usr/bin/env bash
# Confirm the installed Traefik binary exists and reports the pinned version.
set -euo pipefail

DEST="${1:?destination binary path required}"
VERSION="${2:?traefik_version required}"

if [[ ! -x "${DEST}" ]]; then
  exit 1
fi

reported="$("${DEST}" version 2>/dev/null | awk '/^Version:/{print $2; exit}')"
if [[ -z "${reported}" ]]; then
  reported="$("${DEST}" version 2>/dev/null | head -n1 | awk '{print $1}')"
fi
want="${VERSION#v}"
got="${reported#v}"
if [[ -n "${got}" && "${got}" != "${want}" ]]; then
  echo "traefik reports ${reported}, expected ${VERSION}" >&2
  exit 1
fi
echo verified
