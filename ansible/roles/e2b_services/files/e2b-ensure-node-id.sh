#!/usr/bin/env bash
# Persist a stable NODE_ID. Creates the file once; never rotates.
set -euo pipefail

FILE="${1:?node-id file required}"

if [[ -s "${FILE}" ]]; then
  tr -d '[:space:]' <"${FILE}"
  exit 0
fi

mkdir -p "$(dirname "${FILE}")"
if command -v uuidgen >/dev/null 2>&1; then
  id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
else
  id="$(python3 -c 'import uuid; print(uuid.uuid4())')"
fi
umask 077
printf '%s\n' "${id}" >"${FILE}"
printf '%s' "${id}"
