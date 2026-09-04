#!/usr/bin/env bash
# Fail fast when the API binary and postgres migrations are not the same dist.
# The API refuses to start against a database migrated to a different timestamp.
set -euo pipefail

usage() {
  echo "usage: e2b-assert-dist-pair.sh (--dir DIR | --archive TAR.GZ) [--required-patch NAME --required-patch-sha256 SHA256]" >&2
  exit 2
}

DIR=""
ARCHIVE=""
REQUIRED_PATCH_NAME=""
REQUIRED_PATCH_SHA256=""
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
    --required-patch)
      REQUIRED_PATCH_NAME="${2:?}"
      shift 2
      ;;
    --required-patch-sha256)
      REQUIRED_PATCH_SHA256="${2:?}"
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

if [[ -n "${REQUIRED_PATCH_NAME}" ]]; then
  [[ -n "${REQUIRED_PATCH_SHA256}" ]] || {
    echo "required patch checksum is missing" >&2
    exit 1
  }
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  python3 "${HERE}/e2b-verify-build-patches.py" \
    "${BUILD_INFO}" "${REQUIRED_PATCH_NAME}" "${REQUIRED_PATCH_SHA256}"
fi

if [[ -f "${DIR}/SHA256SUMS" ]]; then
  (
    cd "${DIR}"
    sha256sum -c SHA256SUMS
  ) >/dev/null
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRACTOR="${HERE}/e2b-extract-api-migration-timestamp.sh"
if [[ ! -f "${EXTRACTOR}" ]]; then
  echo "timestamp extractor missing: ${EXTRACTOR}" >&2
  exit 1
fi
# shellcheck disable=SC1091
# shellcheck source=e2b-extract-api-migration-timestamp.sh
source "${EXTRACTOR}"
API_TS="$(extract_api_migration_timestamp "${API_BIN}")"

python3 - "${BUILD_INFO}" "${MIGRATIONS}" "${API_BIN}" "${API_TS}" <<'PY'
import json
import pathlib
import sys

build_info_path, migrations_dir, api_bin, api_ts = (
    pathlib.Path(sys.argv[1]),
    pathlib.Path(sys.argv[2]),
    pathlib.Path(sys.argv[3]),
    sys.argv[4].strip(),
)
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

if api_ts != expected:
    print(
        "API/migration pair mismatch: bin/api expectedMigrationTimestamp="
        f"{api_ts} but BUILD_INFO expected_migration_timestamp={expected}. "
        "The API binary and migrations must come from the same dist.",
        file=sys.stderr,
    )
    raise SystemExit(1)
if api_ts != newest:
    print(
        "API/migration pair mismatch: bin/api expectedMigrationTimestamp="
        f"{api_ts} but newest postgres migration prefix is {newest}.",
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
