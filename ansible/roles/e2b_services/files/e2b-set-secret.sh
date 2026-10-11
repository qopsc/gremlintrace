#!/usr/bin/env bash
# Set KEY=value in a dotenv file without printing the value. The value is read
# from stdin so it never appears in a process listing (/proc/*/cmdline).
#   printf '%s' "$value" | e2b-set-secret.sh FILE KEY
# Writes atomically: temp file in the same directory, mode 0600, then rename.
set -euo pipefail

FILE="${1:?secrets file required}"
KEY="${2:?secret key required}"
if [[ $# -gt 2 ]]; then
  echo "e2b-set-secret.sh: the value must be supplied on stdin, not as an argument" >&2
  exit 2
fi
VALUE="$(cat)"
if [[ -z "${VALUE}" ]]; then
  echo "e2b-set-secret.sh: empty value on stdin for ${KEY}" >&2
  exit 1
fi

if [[ ! -f "${FILE}" ]]; then
  echo "secrets file missing: ${FILE}" >&2
  exit 1
fi

SECRET_VALUE="${VALUE}" python3 - "${FILE}" "${KEY}" <<'PY'
import os
import pathlib
import sys
import tempfile

path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
value = os.environ["SECRET_VALUE"]
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

fd, tmp = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write("".join(out))
    os.replace(tmp, path)
    os.chmod(path, 0o600)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
echo updated
