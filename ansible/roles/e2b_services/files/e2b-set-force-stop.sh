#!/usr/bin/env bash
# Set FORCE_STOP in the orchestrator EnvironmentFile. upgrade.yml calls this
# with true before systemctl stop so Firecracker processes in
# /sys/fs/cgroup/e2b/sbx-* are not drained for up to 35 minutes.
set -euo pipefail

ENV_FILE="${1:?orchestrator env file required}"
VALUE="${2:?true or false required}"

case "${VALUE}" in
  true|false) ;;
  *)
    echo "FORCE_STOP value must be true or false, got ${VALUE}" >&2
    exit 1
    ;;
esac

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "orchestrator env missing: ${ENV_FILE}" >&2
  exit 1
fi

python3 - "${ENV_FILE}" "${VALUE}" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = sys.argv[2]
wanted = f"FORCE_STOP={value}"
lines = path.read_text(encoding="utf-8").splitlines()
found = False
changed = False
out = []
for line in lines:
    if line.startswith("FORCE_STOP="):
        found = True
        if line != wanted:
            changed = True
        out.append(wanted)
    else:
        out.append(line)
if not found:
    out.append(wanted)
    changed = True
path.write_text("\n".join(out) + "\n", encoding="utf-8")
print("changed" if changed else "unchanged")
PY
