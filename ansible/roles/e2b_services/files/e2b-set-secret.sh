#!/usr/bin/env bash
# Set KEY=value in a dotenv file without printing the value.
set -euo pipefail

FILE="${1:?secrets file required}"
KEY="${2:?secret key required}"
VALUE="${3:?secret value required}"

if [[ ! -f "${FILE}" ]]; then
  echo "secrets file missing: ${FILE}" >&2
  exit 1
fi

python3 - "${FILE}" "${KEY}" "${VALUE}" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
found = False
out = []
for line in lines:
    stripped = line.rstrip("\n")
    if stripped.startswith(f"{key}="):
        out.append(f"{key}={value}\n")
        found = True
    else:
        out.append(line if line.endswith("\n") else line + "\n")
if not found:
    if out and not out[-1].endswith("\n"):
        out[-1] += "\n"
    out.append(f"{key}={value}\n")
path.write_text("".join(out), encoding="utf-8")
PY
echo updated
