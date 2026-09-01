#!/usr/bin/env bash
set -euo pipefail

URL="${1:?health url required}"
RETRIES="${2:-60}"
DELAY="${3:-2}"
CURL_BIN="${KODUS_CURL_BIN:-curl}"

if ! [[ "${RETRIES}" =~ ^[0-9]+$ && "${DELAY}" =~ ^[0-9]+$ ]]; then
  echo "retries and delay must be integers" >&2
  exit 1
fi

attempt=0
while [[ "${attempt}" -lt "${RETRIES}" ]]; do
  set +e
  status="$("${CURL_BIN}" -sS -o /dev/null -w '%{http_code}' --max-time 5 "${URL}" 2>/dev/null)"
  rc=$?
  set -e
  if [[ "${rc}" -eq 0 && "${status}" == "200" ]]; then
    echo ready
    exit 0
  fi
  attempt=$((attempt + 1))
  if [[ "${attempt}" -lt "${RETRIES}" ]]; then
    sleep "${DELAY}"
  fi
done

echo "timed out waiting for ${URL}" >&2
exit 1
