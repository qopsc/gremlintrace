#!/usr/bin/env bash
# Wait for a URL. HTTP 503 is retried (API is 503 until a node is discovered).
set -euo pipefail

URL="${1:?url required}"
RETRIES="${2:-60}"
DELAY="${3:-2}"
ACCEPT_TCP="${4:-0}"

if ! [[ "${RETRIES}" =~ ^[0-9]+$ && "${DELAY}" =~ ^[0-9]+$ ]]; then
  echo "retries and delay must be integers" >&2
  exit 1
fi

attempt=0
while [[ "${attempt}" -lt "${RETRIES}" ]]; do
  if [[ "${ACCEPT_TCP}" == "1" ]]; then
    hostport="${URL#http://}"
    hostport="${hostport#https://}"
    host="${hostport%%:*}"
    rest="${hostport#*:}"
    port="${rest%%/*}"
    if python3 - "${host}" "${port}" <<'PY'
import socket
import sys

host, port = sys.argv[1], int(sys.argv[2])
try:
    with socket.create_connection((host, port), timeout=2):
        raise SystemExit(0)
except OSError:
    raise SystemExit(1)
PY
    then
      echo ready
      exit 0
    fi
  else
    body_file="$(mktemp)"
    err_file="$(mktemp)"
    set +e
    body="$(curl -sS -o "${body_file}" -w '%{http_code}' --max-time 5 "${URL}" 2>"${err_file}")"
    curl_rc=$?
    set -e
    rm -f "${body_file}" "${err_file}"
    if [[ "${curl_rc}" -eq 0 && "${body}" == "200" ]]; then
      echo ready
      exit 0
    fi
  fi
  attempt=$((attempt + 1))
  sleep "${DELAY}"
done

echo "timed out waiting for ${URL}" >&2
exit 1
