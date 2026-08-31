#!/usr/bin/env bash
# Validate an extracted or packaged e2b dist tarball before release.
set -euo pipefail
export LC_ALL=C

usage() {
  cat <<'EOF'
Usage: validate-e2b-dist.sh --tarball PATH [--versions FILE]

Checks SHA256SUMS, required binaries, BUILD_INFO consistency, and linkage.
EOF
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS_FILE="${REPO_ROOT}/versions.yml"
TARBALL=""

yaml_get() {
  local file="$1"
  local key="$2"
  python3 -c '
import sys
import yaml

path, key = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    data = yaml.safe_load(fh)
print(data[key])
' "${file}" "${key}"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

assert_static() {
  local bin="$1"
  local file_out ldd_out
  file_out="$(file -b "${bin}")"
  grep -qi 'statically linked' <<<"${file_out}" || die "expected statically linked: ${bin} (${file_out})"
  ldd_out="$(ldd "${bin}" 2>&1 || true)"
  grep -q 'libc.so' <<<"${ldd_out}" && die "expected statically linked (ldd shows libc): ${bin}"
}

assert_dynamic() {
  local bin="$1"
  local file_out
  file_out="$(file -b "${bin}")"
  grep -qi 'dynamically linked' <<<"${file_out}" || die "expected dynamically linked: ${bin} (${file_out})"
  ldd "${bin}" | grep -q 'libc.so' || die "expected libc in ldd output: ${bin}"
}

newest_migration_timestamp() {
  local migdir="$1"
  # shellcheck disable=SC2012
  ls "${migdir}" | sed 's/_.*//' | sort | tail -n 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tarball)
      TARBALL="${2:?}"
      shift 2
      ;;
    --versions)
      VERSIONS_FILE="${2:?}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "${TARBALL}" && -f "${TARBALL}" ]] || die "--tarball is required"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/e2b-validate.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

tar -xzf "${TARBALL}" -C "${WORK}"

[[ -f "${WORK}/SHA256SUMS" ]] || die "SHA256SUMS missing"
(
  cd "${WORK}"
  sha256sum -c SHA256SUMS
)

[[ -f "${WORK}/BUILD_INFO" ]] || die "BUILD_INFO missing"

for bin in orchestrator api client-proxy envd e2b-seed goose; do
  [[ -x "${WORK}/bin/${bin}" ]] || die "missing or non-executable: bin/${bin}"
done

clean_nfs="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["clean_nfs_cache"])' "${WORK}/BUILD_INFO")"
if [[ "${clean_nfs}" == "True" || "${clean_nfs}" == "true" ]]; then
  [[ -x "${WORK}/bin/clean-nfs-cache" ]] || die "BUILD_INFO expects clean-nfs-cache binary"
fi

# API refuses to start when the DB migration set is older than expectedMigrationTimestamp.
want_pin="$(yaml_get "${VERSIONS_FILE}" e2b_pin)"
got_pin="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["e2b_pin"])' "${WORK}/BUILD_INFO")"
[[ "${got_pin}" == "${want_pin}" ]] || die "BUILD_INFO e2b_pin ${got_pin} != versions.yml ${want_pin}"

want_ts="$(newest_migration_timestamp "${WORK}/migrations/postgres")"
got_ts="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["expected_migration_timestamp"])' "${WORK}/BUILD_INFO")"
[[ "${got_ts}" == "${want_ts}" ]] || die "BUILD_INFO expected_migration_timestamp ${got_ts} != newest migration ${want_ts}"

assert_static "${WORK}/bin/envd"
assert_static "${WORK}/bin/api"
assert_dynamic "${WORK}/bin/orchestrator"

printf 'validate-e2b-dist: ok (%s)\n' "$(basename "${TARBALL}")"
