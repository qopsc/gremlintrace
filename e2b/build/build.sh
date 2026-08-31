#!/usr/bin/env bash
# Build dist/e2b-<pin7>.tar.gz from the pinned e2b-dev/infra commit plus e2b/patches/.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Overridable for tests. Docker is never invoked except through DOCKER.
DOCKER="${DOCKER:-docker}"
GIT="${GIT:-git}"

VERSIONS_FILE="${REPO_ROOT}/versions.yml"
E2B_PIN_FILE="${REPO_ROOT}/e2b/e2b.pin"
PATCHES_DIR="${REPO_ROOT}/e2b/patches"
DIST_DIR="${SCRIPT_DIR}/dist"
DOCKERFILE="${SCRIPT_DIR}/Dockerfile.build"
SRC=""
DRY_RUN=false
COMPILE=false
CLONE_DIR=""
PATCH_FILES=()
GOWORK_GO_VERSION=""

E2B_REPO_URL="https://github.com/e2b-dev/infra.git"
OTEL_CONFIG_RELPATH="packages/otel-collector/tests/otel-collector.yaml"
CLEAN_NFS_CACHE_RELPATH="packages/orchestrator/cmd/clean-nfs-cache"

usage() {
  cat <<'EOF'
Usage: build.sh [OPTIONS]

Build e2b/build/dist/e2b-<pin7>.tar.gz from versions.yml's e2b_pin plus e2b/patches/.

Options:
  -h, --help           Show this help and exit
      --dry-run        Validate inputs and print the plan; do not clone or invoke Docker
      --compile        In-container entrypoint: compile binaries and pack the tarball
      --src DIR        Use an existing checkout instead of cloning e2b-dev/infra
      --versions FILE  Path to versions.yml (default: repo versions.yml)
      --pin-file FILE  Path to e2b.pin (default: e2b/e2b.pin)
      --patches DIR    Directory of *.patch files (default: e2b/patches)
      --dist DIR       Output directory for the tarball (default: e2b/build/dist)

Environment:
  DOCKER               Docker CLI (default: docker). Tests stub this; never call docker directly.
  GIT                  git CLI (default: git). Tests stub this.
EOF
}

log() {
  printf '%s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

cleanup() {
  if [[ -n "${CLONE_DIR}" && -d "${CLONE_DIR}" ]]; then
    rm -rf "${CLONE_DIR}"
  fi
}
trap cleanup EXIT

yaml_get() {
  local file="$1"
  local key="$2"
  python3 -c '
import sys
import yaml

path, key = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    data = yaml.safe_load(fh)
if not isinstance(data, dict) or key not in data:
    raise SystemExit(f"missing key {key!r} in {path}")
val = data[key]
if val is None or str(val).strip() == "":
    raise SystemExit(f"empty key {key!r} in {path}")
print(val)
' "${file}" "${key}"
}

load_versions() {
  [[ -f "${VERSIONS_FILE}" ]] || die "versions.yml not found: ${VERSIONS_FILE}"
  E2B_PIN="$(yaml_get "${VERSIONS_FILE}" e2b_pin)"
  E2B_DIST_VERSION="$(yaml_get "${VERSIONS_FILE}" e2b_dist_version)"
  E2B_GO_VERSION="$(yaml_get "${VERSIONS_FILE}" e2b_go_version)"
  ENVD_VERSION="$(yaml_get "${VERSIONS_FILE}" envd_version)"
  GOOSE_VERSION="$(yaml_get "${VERSIONS_FILE}" goose_version)"
}

assert_pin_match() {
  [[ -f "${E2B_PIN_FILE}" ]] || die "e2b.pin not found: ${E2B_PIN_FILE}"
  local pin_file
  pin_file="$(tr -d '[:space:]' <"${E2B_PIN_FILE}")"
  if [[ "${pin_file}" != "${E2B_PIN}" ]]; then
    die "e2b.pin (${pin_file}) does not match versions.yml e2b_pin (${E2B_PIN})"
  fi
}

assert_dist_version() {
  local want="${E2B_PIN:0:7}"
  if [[ "${E2B_DIST_VERSION}" != "${want}" ]]; then
    die "e2b_dist_version (${E2B_DIST_VERSION}) != first 7 chars of e2b_pin (${want})"
  fi
}

parse_gowork_go() {
  local f="$1"
  local v
  [[ -f "${f}" ]] || die "go.work not found: ${f}"
  v="$(sed -n 's/^[[:space:]]*go[[:space:]]\{1,\}\([0-9][0-9.]*\).*/\1/p' "${f}" | head -n 1)"
  [[ -n "${v}" ]] || die "could not parse go directive from ${f}"
  printf '%s\n' "${v}"
}

# Print "major minor patch" with missing components as 0 (so 1.26 == 1.26.0).
go_version_triple() {
  local v="$1"
  [[ "${v}" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "invalid Go version: ${v}"
  local -a parts
  IFS=. read -ra parts <<< "${v}"
  printf '%s %s %s' "${parts[0]}" "${parts[1]:-0}" "${parts[2]:-0}"
}

# Comparison rule: e2b_go_version must share major.minor with go.work's `go`
# directive AND be >= that directive as a (major, minor, patch) triple
# (missing patch = 0). So pin 1.26.6 satisfies go 1.26 and go 1.26.6, but not
# go 1.26.7 (too old) or go 1.27 (different minor — a toolchain bump that
# needs versions.yml + the CI matrix, never auto-corrected).
go_pin_satisfies_gowork() {
  local pin="$1"
  local need="$2"
  local p_maj p_min p_pat n_maj n_min n_pat
  local p_triple n_triple
  p_triple="$(go_version_triple "${pin}")"
  n_triple="$(go_version_triple "${need}")"
  read -r p_maj p_min p_pat <<< "${p_triple}"
  read -r n_maj n_min n_pat <<< "${n_triple}"
  if [[ "${p_maj}" != "${n_maj}" || "${p_min}" != "${n_min}" ]]; then
    return 1
  fi
  (( p_pat >= n_pat ))
}

assert_go_toolchain() {
  local src="$1"
  GOWORK_GO_VERSION="$(parse_gowork_go "${src}/go.work")"
  if ! go_pin_satisfies_gowork "${E2B_GO_VERSION}" "${GOWORK_GO_VERSION}"; then
    die "e2b_go_version (${E2B_GO_VERSION}) does not satisfy go.work go ${GOWORK_GO_VERSION}; update versions.yml — do not auto-correct, toolchain bumps need a CI matrix run"
  fi
}

tarball_name() {
  printf 'e2b-%s.tar.gz' "${E2B_DIST_VERSION}"
}

# Populate PATCH_FILES with PATCHES_DIR/*.patch in lexical order.
# nullglob: an empty directory must not yield a literal *.patch.
list_patch_files() {
  local -a raw=()
  PATCH_FILES=()
  [[ -d "${PATCHES_DIR}" ]] || die "patches directory not found: ${PATCHES_DIR}"
  shopt -s nullglob
  raw=("${PATCHES_DIR}"/*.patch)
  shopt -u nullglob
  if (( ${#raw[@]} == 0 )); then
    return 0
  fi
  local p
  while IFS= read -r p; do
    PATCH_FILES+=("${p}")
  done < <(printf '%s\n' "${raw[@]}" | LC_ALL=C sort)
}

print_plan() {
  list_patch_files
  local patch_names="(none)"
  if (( ${#PATCH_FILES[@]} > 0 )); then
    local -a names=()
    local p
    for p in "${PATCH_FILES[@]}"; do
      names+=("$(basename "${p}")")
    done
    patch_names="$(IFS=','; echo "${names[*]}")"
  fi
  cat <<EOF
e2b_pin=${E2B_PIN}
e2b_go_version=${E2B_GO_VERSION}
e2b_dist_version=${E2B_DIST_VERSION}
tarball=$(tarball_name)
image=codereviewer-e2b-build:${E2B_GO_VERSION}
patches=${patch_names}
otel_config=${OTEL_CONFIG_RELPATH}
EOF
}

clone_upstream() {
  local dest="$1"
  log "cloning ${E2B_REPO_URL} at ${E2B_PIN}"
  mkdir -p "${dest}"
  "${GIT}" init --quiet "${dest}"
  "${GIT}" -C "${dest}" remote add origin "${E2B_REPO_URL}"
  "${GIT}" -C "${dest}" fetch --depth 1 origin "${E2B_PIN}"
  "${GIT}" -C "${dest}" checkout --quiet --detach FETCH_HEAD
  local head
  head="$("${GIT}" -C "${dest}" rev-parse HEAD)"
  if [[ "${head}" != "${E2B_PIN}" ]]; then
    die "checked-out SHA ${head} != e2b_pin ${E2B_PIN}"
  fi
}

apply_patches() {
  local src="$1"
  list_patch_files
  if (( ${#PATCH_FILES[@]} == 0 )); then
    log "no patches to apply in ${PATCHES_DIR}"
    return 0
  fi
  local p base
  for p in "${PATCH_FILES[@]}"; do
    base="$(basename "${p}")"
    log "applying patch ${base}"
    if ! "${GIT}" -C "${src}" apply -- "${p}"; then
      die "patch failed to apply: ${base}"
    fi
  done
}

require_docker() {
  if [[ "${DOCKER}" == */* ]]; then
    [[ -x "${DOCKER}" ]] || die "DOCKER is not executable: ${DOCKER}"
    return 0
  fi
  if ! command -v "${DOCKER}" >/dev/null 2>&1; then
    die "docker not found (${DOCKER}); this host cannot run a real E2B build. Use --dry-run or set DOCKER."
  fi
}

# Single Docker indirection. Tests stub DOCKER; --dry-run never calls this.
run_build_container() {
  local src="$1"
  local image="codereviewer-e2b-build:${E2B_GO_VERSION}"

  require_docker
  mkdir -p "${DIST_DIR}"

  log "building image ${image}"
  "${DOCKER}" build \
    --platform linux/amd64 \
    --build-arg "GO_VERSION=${E2B_GO_VERSION}" \
    --build-arg "E2B_PIN=${E2B_PIN}" \
    -t "${image}" \
    -f "${DOCKERFILE}" \
    "${SCRIPT_DIR}"

  log "compiling inside ${image}"
  "${DOCKER}" run --rm \
    --platform linux/amd64 \
    -e "E2B_PIN=${E2B_PIN}" \
    -e "E2B_DIST_VERSION=${E2B_DIST_VERSION}" \
    -e "E2B_GO_VERSION=${E2B_GO_VERSION}" \
    -e "GOWORK_GO_VERSION=${GOWORK_GO_VERSION}" \
    -e "ENVD_VERSION=${ENVD_VERSION}" \
    -e "GOOSE_VERSION=${GOOSE_VERSION}" \
    -e "GOTOOLCHAIN=local" \
    -v "${src}:/src" \
    -v "${DIST_DIR}:/out" \
    -v "${PATCHES_DIR}:/patches:ro" \
    -v "${SCRIPT_DIR}/build.sh:/build.sh:ro" \
    -v "codereviewer-e2b-gomod:/go/pkg/mod" \
    -v "codereviewer-e2b-gocache:/root/.cache/go-build" \
    -w /src \
    "${image}" \
    /build.sh --compile --src /src --dist /out --patches /patches
}

# Replicates packages/api/Makefile:
#   expectedMigration := $(shell ls ../db/migrations | sed 's/_.*//' | sort | tail -n 1)
migration_timestamp() {
  local migdir="$1"
  [[ -d "${migdir}" ]] || die "migrations directory not found: ${migdir}"
  local ts
  # shellcheck disable=SC2012
  ts="$(ls "${migdir}" | sed 's/_.*//' | sort | tail -n 1)"
  [[ -n "${ts}" ]] || die "could not compute expectedMigrationTimestamp from ${migdir}"
  printf '%s\n' "${ts}"
}

parse_envd_version() {
  local f="$1"
  local v
  [[ -f "${f}" ]] || die "envd version file not found: ${f}"
  v="$(sed -n 's/.*Version = "\(.*\)".*/\1/p' "${f}" | head -n 1)"
  [[ -n "${v}" ]] || die "could not parse envd Version from ${f}"
  printf '%s\n' "${v}"
}

parse_goose_version() {
  local f="$1"
  local v
  [[ -f "${f}" ]] || die "go.mod not found: ${f}"
  v="$(sed -n 's/^[[:space:]]*github.com\/pressly\/goose\/v3[[:space:]]\{1,\}\(v[^[:space:]]*\).*/\1/p' "${f}" | head -n 1)"
  [[ -n "${v}" ]] || die "could not parse goose version from ${f}"
  printf '%s\n' "${v}"
}

assert_static() {
  local bin="$1"
  local file_out ldd_out
  [[ -f "${bin}" ]] || die "binary not found: ${bin}"
  file_out="$(file -b "${bin}")"
  if ! grep -qi 'statically linked' <<<"${file_out}"; then
    die "expected statically linked: ${bin} (${file_out})"
  fi
  ldd_out="$(ldd "${bin}" 2>&1 || true)"
  if grep -q 'libc.so' <<<"${ldd_out}"; then
    die "expected statically linked (ldd shows libc): ${bin}"
  fi
}

assert_dynamic() {
  local bin="$1"
  local file_out
  [[ -f "${bin}" ]] || die "binary not found: ${bin}"
  file_out="$(file -b "${bin}")"
  if ! grep -qi 'dynamically linked' <<<"${file_out}"; then
    die "expected dynamically linked: ${bin} (${file_out})"
  fi
  ldd "${bin}" | grep -q 'libc.so' || die "expected libc in ldd output: ${bin}"
}

write_build_info() {
  local dest="$1"
  local clean_json="$2"
  local patches_json="[]"
  local -a patch_items=()
  local p base hash
  [[ -n "${GOWORK_GO_VERSION}" ]] || die "GOWORK_GO_VERSION unset when writing BUILD_INFO"

  list_patch_files
  if (( ${#PATCH_FILES[@]} > 0 )); then
    for p in "${PATCH_FILES[@]}"; do
      base="$(basename "${p}")"
      hash="$(sha256sum "${p}" | awk '{print $1}')"
      patch_items+=("    {\"filename\": \"${base}\", \"sha256\": \"${hash}\"}")
    done
    local IFS=$',\n'
    patches_json=$'[\n'"${patch_items[*]}"$'\n  ]'
  fi

  cat >"${dest}" <<EOF
{
  "e2b_pin": "${E2B_PIN}",
  "e2b_dist_version": "${E2B_DIST_VERSION}",
  "e2b_go_version": "${E2B_GO_VERSION}",
  "gowork_go_version": "${GOWORK_GO_VERSION}",
  "envd_version": "${ENVD_VERSION}",
  "goose_version": "${GOOSE_VERSION}",
  "expected_migration_timestamp": "${EXPECTED_MIGRATION_TIMESTAMP}",
  "built_at_utc": "${BUILT_AT_UTC}",
  "clean_nfs_cache": ${clean_json},
  "patches": ${patches_json}
}
EOF
}

write_sha256sums() {
  local stage="$1"
  (
    cd "${stage}"
    find . -type f ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort | while IFS= read -r f; do
      sha256sum "${f}"
    done
  ) >"${stage}/SHA256SUMS"
}

compile_and_pack() {
  local src="${SRC}"
  [[ -n "${src}" && -d "${src}" ]] || die "--compile requires --src DIR"
  : "${E2B_PIN:?E2B_PIN must be set}"
  : "${E2B_DIST_VERSION:?E2B_DIST_VERSION must be set}"
  : "${E2B_GO_VERSION:?E2B_GO_VERSION must be set}"
  : "${ENVD_VERSION:?ENVD_VERSION must be set}"
  : "${GOOSE_VERSION:?GOOSE_VERSION must be set}"
  : "${DIST_DIR:?}"
  # Installed toolchain only. Without this, modern Go auto-downloads a newer
  # toolchain when go.work/go.mod requires one, and BUILD_INFO.e2b_go_version
  # would label the artifact with a toolchain it was not built with.
  export GOTOOLCHAIN=local

  local head
  head="$("${GIT}" -C "${src}" rev-parse HEAD)"
  if [[ "${head}" != "${E2B_PIN}" ]]; then
    die "source HEAD ${head} != E2B_PIN ${E2B_PIN}"
  fi

  assert_go_toolchain "${src}"

  local src_envd src_goose
  src_envd="$(parse_envd_version "${src}/packages/envd/pkg/version.go")"
  if [[ "${src_envd}" != "${ENVD_VERSION}" ]]; then
    die "envd_version in versions.yml (${ENVD_VERSION}) != ${src}/packages/envd/pkg/version.go (${src_envd})"
  fi
  src_goose="$(parse_goose_version "${src}/packages/db/go.mod")"
  if [[ "${src_goose}" != "${GOOSE_VERSION}" ]]; then
    die "goose_version in versions.yml (${GOOSE_VERSION}) != packages/db/go.mod (${src_goose})"
  fi

  EXPECTED_MIGRATION_TIMESTAMP="$(migration_timestamp "${src}/packages/db/migrations")"
  BUILT_AT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local short="${E2B_DIST_VERSION}"

  log "building orchestrator + clean-nfs-cache (CGO, glibc-dynamic)"
  make -C "${src}/packages/orchestrator" build-local \
    COMMIT_SHA="${short}" BUILD_ARCH=amd64

  log "building api (CGO_ENABLED=0, expectedMigrationTimestamp=${EXPECTED_MIGRATION_TIMESTAMP})"
  make -C "${src}/packages/api" build \
    COMMIT_SHA="${short}" EXPECTED_MIGRATION_TIMESTAMP="${EXPECTED_MIGRATION_TIMESTAMP}"

  log "building client-proxy (CGO_ENABLED=0)"
  make -C "${src}/packages/client-proxy" build \
    COMMIT_SHA="${short}" BUILD_ARCH=amd64

  log "building envd (static, release ldflags)"
  make -C "${src}/packages/envd" build BUILD_ARCH=amd64

  mkdir -p "${src}/packages/db/bin"

  log "building e2b-seed"
  (cd "${src}/packages/db" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -o "${src}/packages/db/bin/e2b-seed" ./scripts/seed/postgres/seed-db.go)

  log "building goose ${GOOSE_VERSION} (static, from packages/db module graph)"
  (cd "${src}/packages/db" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -o "${src}/packages/db/bin/goose" github.com/pressly/goose/v3/cmd/goose)

  local orch_bin="${src}/packages/orchestrator/bin/orchestrator"
  local api_bin="${src}/packages/api/bin/api"
  local proxy_bin="${src}/packages/client-proxy/bin/client-proxy"
  local envd_bin="${src}/packages/envd/bin/envd"
  local seed_bin="${src}/packages/db/bin/e2b-seed"
  local goose_bin="${src}/packages/db/bin/goose"
  local nfs_bin="${src}/packages/orchestrator/bin/clean-nfs-cache"

  assert_static "${api_bin}"
  assert_static "${envd_bin}"
  assert_dynamic "${orch_bin}"
  [[ -f "${proxy_bin}" ]] || die "client-proxy binary missing"
  [[ -f "${seed_bin}" ]] || die "e2b-seed binary missing"
  [[ -f "${goose_bin}" ]] || die "goose binary missing"
  assert_static "${goose_bin}"

  local clean_json="false"
  if [[ -d "${src}/${CLEAN_NFS_CACHE_RELPATH}" ]]; then
    [[ -f "${nfs_bin}" ]] || die "clean-nfs-cache was expected at this pin but was not built"
    clean_json="true"
  else
    log "clean-nfs-cache not present at this pin; omitting"
    nfs_bin=""
  fi

  local stage
  stage="$(mktemp -d "${TMPDIR:-/tmp}/e2b-dist.XXXXXX")"
  mkdir -p "${stage}/bin" "${stage}/migrations/postgres" "${stage}/migrations/clickhouse"

  install -m 0755 "${orch_bin}" "${stage}/bin/orchestrator"
  install -m 0755 "${api_bin}" "${stage}/bin/api"
  install -m 0755 "${proxy_bin}" "${stage}/bin/client-proxy"
  install -m 0755 "${envd_bin}" "${stage}/bin/envd"
  install -m 0755 "${seed_bin}" "${stage}/bin/e2b-seed"
  install -m 0755 "${goose_bin}" "${stage}/bin/goose"
  if [[ -n "${nfs_bin}" ]]; then
    install -m 0755 "${nfs_bin}" "${stage}/bin/clean-nfs-cache"
  fi

  local -a pg_sql=() ch_sql=()
  shopt -s nullglob
  pg_sql=("${src}/packages/db/migrations/"*.sql)
  ch_sql=("${src}/packages/clickhouse/migrations/"*.sql)
  shopt -u nullglob
  (( ${#pg_sql[@]} > 0 )) || die "no postgres migrations in ${src}/packages/db/migrations"
  (( ${#ch_sql[@]} > 0 )) || die "no clickhouse migrations in ${src}/packages/clickhouse/migrations"
  cp "${pg_sql[@]}" "${stage}/migrations/postgres/"
  cp "${ch_sql[@]}" "${stage}/migrations/clickhouse/"

  local otel_src="${src}/${OTEL_CONFIG_RELPATH}"
  [[ -f "${otel_src}" ]] || die "otel-collector config not found: ${otel_src}"
  cp "${otel_src}" "${stage}/otel-collector.yaml"

  write_build_info "${stage}/BUILD_INFO" "${clean_json}"
  write_sha256sums "${stage}"
  (cd "${stage}" && sha256sum -c SHA256SUMS)

  mkdir -p "${DIST_DIR}"
  local out
  out="${DIST_DIR}/$(tarball_name)"
  tar -C "${stage}" -czf "${out}" \
    bin migrations otel-collector.yaml SHA256SUMS BUILD_INFO
  rm -rf "${stage}"
  log "wrote ${out}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --compile)
        COMPILE=true
        shift
        ;;
      --src)
        [[ $# -ge 2 ]] || die "--src requires a directory"
        SRC="$2"
        shift 2
        ;;
      --versions)
        [[ $# -ge 2 ]] || die "--versions requires a file"
        VERSIONS_FILE="$2"
        shift 2
        ;;
      --pin-file)
        [[ $# -ge 2 ]] || die "--pin-file requires a file"
        E2B_PIN_FILE="$2"
        shift 2
        ;;
      --patches)
        [[ $# -ge 2 ]] || die "--patches requires a directory"
        PATCHES_DIR="$2"
        shift 2
        ;;
      --dist)
        [[ $# -ge 2 ]] || die "--dist requires a directory"
        DIST_DIR="$2"
        shift 2
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  if [[ "${COMPILE}" == true ]]; then
    compile_and_pack
    return 0
  fi

  load_versions
  assert_pin_match
  assert_dist_version

  if [[ "${DRY_RUN}" == true ]]; then
    print_plan
    return 0
  fi

  local src="${SRC}"
  if [[ -z "${src}" ]]; then
    CLONE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/e2b-infra-build.XXXXXX")"
    clone_upstream "${CLONE_DIR}"
    src="${CLONE_DIR}"
  else
    [[ -d "${src}" ]] || die "--src is not a directory: ${src}"
    local head
    head="$("${GIT}" -C "${src}" rev-parse HEAD)"
    if [[ "${head}" != "${E2B_PIN}" ]]; then
      die "--src HEAD ${head} != e2b_pin ${E2B_PIN}"
    fi
  fi

  apply_patches "${src}"
  assert_go_toolchain "${src}"
  run_build_container "${src}"
}

main "$@"
