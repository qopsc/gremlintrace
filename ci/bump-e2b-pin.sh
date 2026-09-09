#!/usr/bin/env bash
# Resolve upstream e2b-dev/infra HEAD and update versions.yml + e2b/e2b.pin when it moved.
set -euo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS_FILE="${REPO_ROOT}/versions.yml"
PIN_FILE="${REPO_ROOT}/e2b/e2b.pin"
UPSTREAM_URL="${E2B_UPSTREAM_URL:-https://github.com/e2b-dev/infra.git}"
ARTIFACT_BASE_URL="${E2B_ARTIFACT_BASE_URL:-https://storage.googleapis.com/e2b-artifact-binaries}"
GIT_CMD="${E2B_GIT:-git}"
CURL_CMD="${E2B_CURL:-curl}"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

yaml_get() {
  python3 "${REPO_ROOT}/ci/yaml_versions.py" get "$1" "${VERSIONS_FILE}"
}

latest_upstream_sha() {
  "${GIT_CMD}" ls-remote "${UPSTREAM_URL}" HEAD | awk 'NR==1 {print $1}'
}

parse_envd_version() {
  local f="$1"
  sed -n 's/.*Version = "\(.*\)".*/\1/p' "${f}" | head -n 1
}

parse_goose_version() {
  local f="$1"
  sed -n 's/^[[:space:]]*github.com\/pressly\/goose\/v3[[:space:]]\{1,\}\(v[^[:space:]]*\).*/\1/p' "${f}" | head -n 1
}

parse_gowork_go() {
  local f="$1"
  sed -n 's/^[[:space:]]*go[[:space:]]\{1,\}\([0-9][0-9.]*\).*/\1/p' "${f}" | head -n 1
}

parse_go_const_value() {
  local f="$1"
  local name="$2"
  local value symbol
  value="$(sed -n \
    -e "s/^[[:space:]]*${name}[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
    -e "s/^[[:space:]]*const[[:space:]]\{1,\}${name}[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
    "${f}" | head -n 1)"
  if [[ -n "${value}" ]]; then
    printf '%s\n' "${value}"
    return 0
  fi
  symbol="$(sed -n \
    -e "s/^[[:space:]]*${name}[[:space:]]*=[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\).*/\1/p" \
    -e "s/^[[:space:]]*const[[:space:]]\{1,\}${name}[[:space:]]*=[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\).*/\1/p" \
    "${f}" | head -n 1)"
  [[ -n "${symbol}" ]] || return 0
  sed -n \
    -e "s/^[[:space:]]*${symbol}[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
    -e "s/^[[:space:]]*const[[:space:]]\{1,\}${symbol}[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
    "${f}" | head -n 1
}

artifact_url() {
  local kind="$1"
  local version="$2"
  case "${kind}" in
    firecracker)
      printf '%s/firecrackers/%s/amd64/firecracker\n' "${ARTIFACT_BASE_URL}" "${version}"
      ;;
    kernel)
      printf '%s/kernels/%s/amd64/vmlinux.bin\n' "${ARTIFACT_BASE_URL}" "${version}"
      ;;
    busybox)
      printf '%s/busybox/%s/amd64/busybox\n' "${ARTIFACT_BASE_URL}" "${version}"
      ;;
    *)
      die "unknown artifact kind: ${kind}"
      ;;
  esac
}

download_artifact_hash() {
  local kind="$1"
  local version="$2"
  local dest="${work}/${kind}-${version}"
  mkdir -p "${work}"
  "${CURL_CMD}" -fsSL -o "${dest}" "$(artifact_url "${kind}" "${version}")"
  sha256sum "${dest}" | awk '{print $1}'
}

validate_hash_pin() {
  local kind="$1"
  local version="$2"
  local expected="$3"
  local actual
  [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] || die "invalid ${kind} SHA-256 pin: ${expected}"
  actual="$(download_artifact_hash "${kind}" "${version}")"
  [[ "${actual}" == "${expected}" ]] || die "${kind}/${version} checksum mismatch: expected ${expected}, got ${actual}"
}

validate_current_artifact_pins() {
  validate_hash_pin firecracker "${current_fc_ver}" "${current_fc_sha256}"
  validate_hash_pin kernel "${current_kernel_ver}" "${current_kernel_sha256}"
  validate_hash_pin busybox "${current_busybox_ver}" "${current_busybox_sha256}"
}

current_pin="$(yaml_get e2b_pin)"
current_fc_ver="$(yaml_get firecracker_version)"
current_kernel_ver="$(yaml_get kernel_version)"
current_busybox_ver="$(yaml_get busybox_version)"
current_fc_sha256="$(yaml_get firecracker_sha256)"
current_kernel_sha256="$(yaml_get kernel_sha256)"
current_busybox_sha256="$(yaml_get busybox_sha256)"
latest="$(latest_upstream_sha)"
[[ -n "${latest}" ]] || die "could not resolve upstream HEAD"

work="$(mktemp -d "${TMPDIR:-/tmp}/e2b-bump.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

if [[ "${latest}" == "${current_pin}" ]]; then
  validate_current_artifact_pins
  printf 'bump-e2b-pin: already at %s\n' "${current_pin}"
  exit 0
fi

"${GIT_CMD}" clone --depth 1 "${UPSTREAM_URL}" "${work}/infra" >/dev/null
head="$("${GIT_CMD}" -C "${work}/infra" rev-parse HEAD)"
[[ "${head}" == "${latest}" ]] || die "shallow clone HEAD ${head} != ls-remote ${latest}"

envd_ver="$(parse_envd_version "${work}/infra/packages/envd/pkg/version.go")"
[[ -n "${envd_ver}" ]] || die "could not parse envd version"
goose_ver="$(parse_goose_version "${work}/infra/packages/db/go.mod")"
[[ -n "${goose_ver}" ]] || die "could not parse goose version"
go_ver="$(parse_gowork_go "${work}/infra/go.work")"
[[ -n "${go_ver}" ]] || die "could not parse go.work go directive"
flags_file="${work}/infra/packages/shared/pkg/featureflags/flags.go"
orchestrator_model="${work}/infra/packages/orchestrator/pkg/cfg/model.go"
[[ -f "${flags_file}" ]] || die "could not find upstream feature flags source"
[[ -f "${orchestrator_model}" ]] || die "could not find upstream orchestrator config source"
firecracker_ver="$(parse_go_const_value "${flags_file}" DefaultFirecrackerVersion)"
kernel_ver="$(parse_go_const_value "${flags_file}" DefaultKernelVersion)"
busybox_ver="$(parse_go_const_value "${orchestrator_model}" DefaultBusyboxVersion)"
[[ -n "${firecracker_ver}" ]] || die "could not parse upstream Firecracker version"
[[ -n "${kernel_ver}" ]] || die "could not parse upstream kernel version"
[[ -n "${busybox_ver}" ]] || die "could not parse upstream busybox version"
firecracker_sha256="$(download_artifact_hash firecracker "${firecracker_ver}")"
kernel_sha256="$(download_artifact_hash kernel "${kernel_ver}")"
busybox_sha256="$(download_artifact_hash busybox "${busybox_ver}")"
[[ "${firecracker_sha256}" =~ ^[0-9a-f]{64}$ ]] || die "invalid downloaded Firecracker checksum"
[[ "${kernel_sha256}" =~ ^[0-9a-f]{64}$ ]] || die "invalid downloaded kernel checksum"
[[ "${busybox_sha256}" =~ ^[0-9a-f]{64}$ ]] || die "invalid downloaded busybox checksum"
dist_ver="${latest:0:7}"

python3 "${REPO_ROOT}/ci/yaml_versions.py" update "${VERSIONS_FILE}" \
  "e2b_pin=${latest}" \
  "e2b_dist_version=${dist_ver}" \
  "envd_version=${envd_ver}" \
  "goose_version=${goose_ver}" \
  "e2b_go_version=${go_ver}" \
  "firecracker_version=${firecracker_ver}" \
  "kernel_version=${kernel_ver}" \
  "busybox_version=${busybox_ver}" \
  "firecracker_sha256=${firecracker_sha256}" \
  "kernel_sha256=${kernel_sha256}" \
  "busybox_sha256=${busybox_sha256}"

printf '%s\n' "${latest}" >"${PIN_FILE}"
printf 'bump-e2b-pin: %s -> %s (go=%s envd=%s goose=%s firecracker=%s kernel=%s busybox=%s)\n' \
  "${current_pin}" "${latest}" "${go_ver}" "${envd_ver}" "${goose_ver}" \
  "${firecracker_ver}" "${kernel_ver}" "${busybox_ver}"
