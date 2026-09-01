#!/usr/bin/env bash
# Print one KEY=value from a dotenv file to stdout. Callers must not log this.
set -euo pipefail

FILE="${1:?secrets file required}"
KEY="${2:?secret key required}"

if [[ ! -f "${FILE}" ]]; then
  echo "secrets file missing: ${FILE}" >&2
  exit 1
fi

python3 - "${FILE}" "${KEY}" <<'PY'
import sys

path, key = sys.argv[1], sys.argv[2]
value = None
with open(path, encoding="utf-8") as handle:
    for raw in handle:
        line = raw.rstrip("\n")
        if not line or line.lstrip().startswith("#"):
            continue
        if line.startswith(f"{key}="):
            value = line.split("=", 1)[1]
if value is None:
    raise SystemExit(f"missing key {key}")
sys.stdout.write(value)
PY
