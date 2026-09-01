#!/usr/bin/env bash
# Minimal Kodus smoke after doctor: health endpoints + synthetic webhook.
set -euo pipefail

for url in \
  http://127.0.0.1:3000/health \
  http://127.0.0.1:3001/health \
  http://127.0.0.1:3332/health
do
  code="$(curl -fsS -o /dev/null -w '%{http_code}' "${url}")"
  if [[ "${code}" != "200" ]]; then
    echo "kodus health ${url} returned ${code}" >&2
    exit 1
  fi
done

./ci/matrix/synthetic-github-webhook.sh
printf 'kodus-smoke: ok\n'
