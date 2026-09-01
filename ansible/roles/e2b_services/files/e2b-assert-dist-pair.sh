#!/usr/bin/env bash
# Fail fast when the API binary and postgres migrations are not the same dist.
# The API refuses to start against a database migrated to a different timestamp.
set -euo pipefail

usage() {
  echo "usage: e2b-assert-dist-pair.sh --dir DIR | --archive TAR.GZ" >&2
  exit 2
}

DIR=""
ARCHIVE=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dir)
      DIR="${2:?}"
      shift 2
      ;;
    --archive)
      ARCHIVE="${2:?}"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      ;;
  esac
done

STAGE=""
cleanup() {
  if [[ -n "${STAGE}" && -d "${STAGE}" ]]; then
    rm -rf "${STAGE}"
  fi
}
trap cleanup EXIT

if [[ -n "${ARCHIVE}" ]]; then
  if [[ ! -f "${ARCHIVE}" ]]; then
    echo "dist archive missing: ${ARCHIVE}" >&2
    exit 1
  fi
  STAGE="$(mktemp -d)"
  tar -xzf "${ARCHIVE}" -C "${STAGE}"
  DIR="${STAGE}"
fi

if [[ -z "${DIR}" || ! -d "${DIR}" ]]; then
  echo "dist directory missing" >&2
  exit 1
fi

BUILD_INFO="${DIR}/BUILD_INFO"
API_BIN="${DIR}/bin/api"
MIGRATIONS="${DIR}/migrations/postgres"

if [[ ! -f "${BUILD_INFO}" ]]; then
  echo "BUILD_INFO missing from dist; cannot verify API/migration pair" >&2
  exit 1
fi
if [[ ! -e "${API_BIN}" ]]; then
  echo "API binary missing at ${API_BIN}; refusing a mismatched API/migration pair" >&2
  exit 1
fi
if [[ ! -d "${MIGRATIONS}" ]]; then
  echo "postgres migrations missing at ${MIGRATIONS}" >&2
  exit 1
fi

if [[ -f "${DIR}/SHA256SUMS" ]]; then
  (
    cd "${DIR}"
    sha256sum -c SHA256SUMS
  ) >/dev/null
fi

python3 - "${BUILD_INFO}" "${MIGRATIONS}" "${API_BIN}" <<'PY'
import json
import pathlib
import sys

build_info_path, migrations_dir, api_bin = (pathlib.Path(p) for p in sys.argv[1:])
data = json.loads(build_info_path.read_text(encoding="utf-8"))
expected = str(data.get("expected_migration_timestamp") or "").strip()
if not expected:
    print("BUILD_INFO missing expected_migration_timestamp; refusing mismatched pair", file=sys.stderr)
    raise SystemExit(1)

prefixes = []
for path in migrations_dir.iterdir():
    if not path.is_file():
        continue
    name = path.name
    if name.startswith("."):
        continue
    prefix = name.split("_", 1)[0]
    if prefix.isdigit():
        prefixes.append(prefix)
if not prefixes:
    print(f"no postgres migration files under {migrations_dir}", file=sys.stderr)
    raise SystemExit(1)
newest = max(prefixes)
if newest != expected:
    print(
        "API/migration pair mismatch: BUILD_INFO expected_migration_timestamp="
        f"{expected} but newest postgres migration prefix is {newest}. "
        "The API binary and migrations must come from the same dist.",
        file=sys.stderr,
    )
    raise SystemExit(1)

api_root = api_bin.resolve().parent.parent
mig_root = migrations_dir.resolve().parent.parent
if api_root != mig_root:
    print(
        f"API binary tree {api_root} is not the same dist as migrations {mig_root}",
        file=sys.stderr,
    )
    raise SystemExit(1)

print("ok")
PY
