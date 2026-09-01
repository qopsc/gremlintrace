#!/usr/bin/env bash
# Run build-templates.ts, parse the last stdout JSON line, fail on any failed alias.
set -euo pipefail

INSTALL_DIR="${1:?templates install dir required}"
SUMMARY_PATH="${2:?summary output path required}"
NPM_BIN="${3:-npm}"
NODE_IMAGE="${4:-}"

if [[ ! -f "${INSTALL_DIR}/package.json" ]]; then
  echo "templates are not installed at ${INSTALL_DIR}" >&2
  exit 1
fi

lock_stamp="${INSTALL_DIR}/.npm-ci-stamp"
lock_hash="$(sha256sum "${INSTALL_DIR}/package-lock.json" | awk '{print $1}')"
need_ci=1
if [[ -f "${lock_stamp}" && -d "${INSTALL_DIR}/node_modules" ]]; then
  if [[ "$(cat "${lock_stamp}")" == "${lock_hash}" ]]; then
    need_ci=0
  fi
fi
run_npm() {
  if [[ -n "${NODE_IMAGE}" ]]; then
    docker run --rm --network host \
      --volume "${INSTALL_DIR}:/work" \
      --workdir /work \
      --env E2B_API_KEY \
      --env E2B_API_URL \
      --env E2B_DOMAIN \
      --env E2B_TEMPLATE_FORCE \
      --env E2B_BASE_IMAGE \
      "${NODE_IMAGE}" \
      npm "$@"
  else
    (
      cd "${INSTALL_DIR}"
      "${NPM_BIN}" "$@"
    )
  fi
}

if [[ "${need_ci}" -eq 1 ]]; then
  run_npm ci >&2
  printf '%s\n' "${lock_hash}" >"${lock_stamp}"
fi

stdout_file="$(mktemp)"
stderr_file="$(mktemp)"
trap 'rm -f "${stdout_file}" "${stderr_file}"' EXIT

set +e
run_npm run build-templates >"${stdout_file}" 2>"${stderr_file}"
rc=$?
set -e

cat "${stderr_file}" >&2
summary="$(python3 - "${stdout_file}" <<'PY'
import json
import sys

lines = [line.rstrip("\n") for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
if not lines:
    raise SystemExit("build-templates produced no stdout")
raw = lines[-1]
try:
    data = json.loads(raw)
except json.JSONDecodeError as exc:
    raise SystemExit(f"last stdout line is not JSON: {raw!r} ({exc})") from exc
if not isinstance(data, dict) or "templates" not in data:
    raise SystemExit(f"summary missing templates: {raw}")
print(raw)
PY
)"

mkdir -p "$(dirname "${SUMMARY_PATH}")"
umask 077
printf '%s\n' "${summary}" >"${SUMMARY_PATH}"

python3 - "${SUMMARY_PATH}" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
failed = [row["alias"] for row in data.get("templates", []) if row.get("action") == "failed"]
if failed:
    raise SystemExit("template build failed for: " + ", ".join(failed))
PY

if [[ "${rc}" -ne 0 ]]; then
  exit "${rc}"
fi

python3 - "${SUMMARY_PATH}" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
built = [row["alias"] for row in data.get("templates", []) if row.get("action") == "built"]
print("changed" if built else "unchanged")
PY

