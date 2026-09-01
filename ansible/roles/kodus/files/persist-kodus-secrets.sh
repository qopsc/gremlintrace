#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:?kodus .env path required}"
PERSIST_FILE="${2:?generated-secrets persist path required}"
GENERATE_SCRIPT="${3:?generate-secrets.sh path required}"
SCHEMA_FILE="${4:?schema-vars.sh path required}"
MARKER="${KODUS_SECRETS_MARKER:-}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "missing .env: ${ENV_FILE}" >&2
  exit 1
fi
if [[ ! -f "${GENERATE_SCRIPT}" ]]; then
  echo "missing generate-secrets.sh: ${GENERATE_SCRIPT}" >&2
  exit 1
fi
if [[ ! -f "${SCHEMA_FILE}" ]]; then
  echo "missing schema-vars.sh: ${SCHEMA_FILE}" >&2
  exit 1
fi

# shellcheck disable=SC1090
. "${SCHEMA_FILE}"

persist_dir="$(dirname "${PERSIST_FILE}")"
mkdir -p "${persist_dir}"
chmod 0750 "${persist_dir}" 2>/dev/null || true

keys=()
for entry in "${KODUS_AUTOGEN_SECRETS[@]}"; do
  keys+=("${entry%%=*}")
done

persist_complete() {
  [[ -f "${PERSIST_FILE}" ]] || return 1
  python3 - "${PERSIST_FILE}" "${keys[@]}" <<'PY'
import sys

path = sys.argv[1]
needed = sys.argv[2:]
values = {}
with open(path, encoding="utf-8") as handle:
    for raw in handle:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value
for key in needed:
    if not values.get(key):
        raise SystemExit(1)
PY
}

merge_persist_into_env() {
  python3 - "${ENV_FILE}" "${PERSIST_FILE}" <<'PY'
import os
import pathlib
import re
import sys
import tempfile

env_path = pathlib.Path(sys.argv[1])
persist_path = pathlib.Path(sys.argv[2])
assign = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
persist = {}
for raw in persist_path.read_text(encoding="utf-8").splitlines():
    match = assign.match(raw.strip())
    if match:
        persist[match.group(1)] = match.group(2)
text = env_path.read_text(encoding="utf-8") if env_path.is_file() else ""
out = []
seen = set()
for raw in text.splitlines():
    match = assign.match(raw.strip())
    if match and match.group(1) in persist:
        out.append(f"{match.group(1)}={persist[match.group(1)]}")
        seen.add(match.group(1))
    else:
        out.append(raw)
for key, value in persist.items():
    if key not in seen:
        out.append(f"{key}={value}")
content = "\n".join(out) + "\n"
if env_path.is_file() and env_path.read_text(encoding="utf-8") == content:
    raise SystemExit(0)
fd, tmp = tempfile.mkstemp(prefix=f".{env_path.name}.", dir=str(env_path.parent), text=True)
os.write(fd, content.encode("utf-8"))
os.close(fd)
os.chmod(tmp, 0o600)
os.replace(tmp, env_path)
os.chmod(env_path, 0o600)
PY
}

extract_env_to_persist() {
  python3 - "${ENV_FILE}" "${PERSIST_FILE}" "${keys[@]}" <<'PY'
import os
import pathlib
import re
import sys
import tempfile

env_path = pathlib.Path(sys.argv[1])
persist_path = pathlib.Path(sys.argv[2])
needed = sys.argv[3:]
assign = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
values = {}
for raw in env_path.read_text(encoding="utf-8").splitlines():
    match = assign.match(raw.strip())
    if match:
        values[match.group(1)] = match.group(2)
missing = [key for key in needed if not values.get(key)]
if missing:
    raise SystemExit("generate-secrets.sh did not set: " + ", ".join(missing))
lines = [f"{key}={values[key]}" for key in needed]
content = "\n".join(lines) + "\n"
persist_path.parent.mkdir(parents=True, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=f".{persist_path.name}.", dir=str(persist_path.parent), text=True)
os.write(fd, content.encode("utf-8"))
os.close(fd)
os.chmod(tmp, 0o600)
os.replace(tmp, persist_path)
os.chmod(persist_path, 0o600)
PY
}

if persist_complete; then
  merge_persist_into_env
  echo reused
  if [[ -n "${MARKER}" ]]; then
    printf 'reused\n' >>"${MARKER}"
  fi
  exit 0
fi

installer_dir="$(cd "$(dirname "${ENV_FILE}")" && pwd)"
(
  cd "${installer_dir}"
  bash "${GENERATE_SCRIPT}"
)
extract_env_to_persist
echo generated
if [[ -n "${MARKER}" ]]; then
  printf 'generated\n' >>"${MARKER}"
fi
