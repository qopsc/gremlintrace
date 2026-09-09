#!/usr/bin/env bash
# Set FORCE_STOP in the orchestrator EnvironmentFile and manage the
# /orchestrator/force-stop marker that the patched orchestrator consults at
# shutdown-signal receipt (FORCE_STOP is parsed once at process start, so
# rewriting the env file alone does not affect a running process).
#
# Interface:
#   Marker path: ${QOPS_FORCE_STOP_MARKER:-/orchestrator/force-stop}
#   Empty file, mode 0600, root-owned when created as root.
#   Presence at SIGTERM => treat as ForceStop=true. Keep FORCE_STOP=true in
#   the env file so a restart also force-stops. Remove the marker after a
#   successful stop (or on the subsequent start) so an ordinary later stop
#   still drains.
set -euo pipefail

MARKER="${QOPS_FORCE_STOP_MARKER:-/orchestrator/force-stop}"

usage() {
  echo "usage: e2b-set-force-stop.sh ENV_FILE true|false | --clear-marker" >&2
  exit 2
}

create_marker() {
  local dir
  dir="$(dirname "${MARKER}")"
  if [[ ! -d "${dir}" ]]; then
    echo "force-stop marker directory missing: ${dir}" >&2
    exit 1
  fi
  umask 077
  : >"${MARKER}"
  chmod 0600 "${MARKER}"
  if [[ "$(id -u)" -eq 0 ]]; then
    chown root:root "${MARKER}"
  fi
}

clear_marker() {
  rm -f "${MARKER}"
}

if [[ "${1:-}" == "--clear-marker" ]]; then
  clear_marker
  echo cleared
  exit 0
fi

ENV_FILE="${1:-}"
VALUE="${2:-}"
if [[ -z "${ENV_FILE}" || -z "${VALUE}" ]]; then
  usage
fi

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

if [[ "${VALUE}" == "true" ]]; then
  create_marker
else
  clear_marker
fi
