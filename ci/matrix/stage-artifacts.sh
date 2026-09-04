#!/usr/bin/env bash
# Stage E2B dist and FC artifact tarballs for localhost install (paths in ci/matrix/group_vars).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGE_DIR="${QOPS_CI_STAGE_DIR:-/var/cache/qops/ci}"
DIST_OUT="${STAGE_DIR}/e2b-dist.tar.gz"
FC_OUT="${STAGE_DIR}/e2b-fc-artifacts.tar.gz"

mkdir -p "${STAGE_DIR}"

cd "${REPO_ROOT}"
./e2b/build/build.sh

E2B_DIST_VERSION="$(python3 ci/yaml_versions.py get e2b_dist_version versions.yml)"
DIST_SRC="${REPO_ROOT}/e2b/build/dist/e2b-${E2B_DIST_VERSION}.tar.gz"
if [[ ! -f "${DIST_SRC}" ]]; then
  echo "dist tarball missing: ${DIST_SRC}" >&2
  exit 1
fi
cp -f "${DIST_SRC}" "${DIST_OUT}"
(cd "${STAGE_DIR}" && sha256sum "$(basename "${DIST_OUT}")") >"${DIST_OUT}.sha256"

ARTIFACTS_DIR="${STAGE_DIR}/fc-artifacts-src"
rm -rf "${ARTIFACTS_DIR}"
./ci/mirror-e2b-artifacts.sh --out "${ARTIFACTS_DIR}"
./ci/pack-mirrored-artifacts.sh \
  --artifacts "${ARTIFACTS_DIR}" \
  --out "${FC_OUT}"

printf 'staged dist=%s fc=%s\n' "${DIST_OUT}" "${FC_OUT}"
