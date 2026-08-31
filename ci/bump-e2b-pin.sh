#!/usr/bin/env bash
# Resolve upstream e2b-dev/infra HEAD and update versions.yml + e2b/e2b.pin when it moved.
set -euo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS_FILE="${REPO_ROOT}/versions.yml"
PIN_FILE="${REPO_ROOT}/e2b/e2b.pin"
UPSTREAM_URL="https://github.com/e2b-dev/infra.git"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

latest_upstream_sha() {
  git ls-remote "${UPSTREAM_URL}" HEAD | awk 'NR==1 {print $1}'
}

parse_envd_version() {
  local f="$1"
  sed -n 's/.*Version = "\(.*\)".*/\1/p' "${f}" | head -n 1
}

parse_goose_version() {
  local f="$1"
  sed -n 's/^[[:space:]]*github.com\/pressly\/goose\/v3[[:space:]]\{1,\}\(v[^[:space:]]*\).*/\1/p' "${f}" | head -n 1
}

current_pin="$(python3 -c 'import yaml; print(yaml.safe_load(open("'"${VERSIONS_FILE}"'"))["e2b_pin"])')"
latest="$(latest_upstream_sha)"
[[ -n "${latest}" ]] || die "could not resolve upstream HEAD"

if [[ "${latest}" == "${current_pin}" ]]; then
  printf 'bump-e2b-pin: already at %s\n' "${current_pin}"
  exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/e2b-bump.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

git clone --depth 1 "${UPSTREAM_URL}" "${work}/infra" >/dev/null
head="$(git -C "${work}/infra" rev-parse HEAD)"
[[ "${head}" == "${latest}" ]] || die "shallow clone HEAD ${head} != ls-remote ${latest}"

envd_ver="$(parse_envd_version "${work}/infra/packages/envd/pkg/version.go")"
[[ -n "${envd_ver}" ]] || die "could not parse envd version"
goose_ver="$(parse_goose_version "${work}/infra/packages/db/go.mod")"
[[ -n "${goose_ver}" ]] || die "could not parse goose version"
dist_ver="${latest:0:7}"

python3 - "${VERSIONS_FILE}" "${latest}" "${dist_ver}" "${envd_ver}" "${goose_ver}" <<'PY'
import sys
import yaml

path, pin, dist, envd, goose = sys.argv[1:6]
with open(path, encoding="utf-8") as fh:
    data = yaml.safe_load(fh)
data["e2b_pin"] = pin
data["e2b_dist_version"] = dist
data["envd_version"] = envd
data["goose_version"] = goose
with open(path, "w", encoding="utf-8") as fh:
    yaml.safe_dump(data, fh, default_flow_style=False, sort_keys=False)
PY

printf '%s\n' "${latest}" >"${PIN_FILE}"
printf 'bump-e2b-pin: %s -> %s (envd=%s goose=%s)\n' "${current_pin}" "${latest}" "${envd_ver}" "${goose_ver}"
