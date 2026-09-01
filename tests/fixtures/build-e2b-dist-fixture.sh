#!/usr/bin/env bash
# Build a minimal e2b dist tarball for install/verify tests.
set -euo pipefail

OUT="${1:?output tar.gz path required}"
VERSION="${2:-6e4ce14}"

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

mkdir -p "${STAGE}/bin" "${STAGE}/migrations/postgres" "${STAGE}/migrations/clickhouse"
for bin in orchestrator api client-proxy envd e2b-seed goose clean-nfs-cache; do
  if [[ "${bin}" == "api" ]]; then
    # 14-digit expectedMigrationTimestamp on its own line for strings(1).
    printf '#!/bin/sh\n%s\necho %s\n' "20240101000000" "${bin}" >"${STAGE}/bin/${bin}"
  else
    printf '#!/bin/sh\necho %s\n' "${bin}" >"${STAGE}/bin/${bin}"
  fi
  chmod 755 "${STAGE}/bin/${bin}"
done
printf -- '-- +goose Up\nSELECT 1;\n' >"${STAGE}/migrations/postgres/20240101000000_init.sql"
printf -- '-- +goose Up\nSELECT 1;\n' >"${STAGE}/migrations/clickhouse/20240101000000_init.sql"
printf 'receivers: {}\n' >"${STAGE}/otel-collector.yaml"
python3 - "${STAGE}/BUILD_INFO" "${VERSION}" <<'PY'
import json
import sys

path, version = sys.argv[1], sys.argv[2]
json.dump(
    {
        "e2b_pin": "6e4ce14cdd12c4d6bca1ecf795840b3b9afba0a2",
        "e2b_dist_version": version,
        "e2b_go_version": "1.26.6",
        "gowork_go_version": "1.26.6",
        "envd_version": "0.7.0",
        "goose_version": "v3.27.2",
        "expected_migration_timestamp": "20240101000000",
        "built_at_utc": "2026-08-31T00:00:00Z",
        "clean_nfs_cache": True,
        "patches": [],
    },
    open(path, "w", encoding="utf-8"),
    indent=2,
)
PY

(
  cd "${STAGE}"
  find bin migrations otel-collector.yaml BUILD_INFO -type f | LC_ALL=C sort | while IFS= read -r f; do
    sha256sum "${f}"
  done
) >"${STAGE}/SHA256SUMS"

tar -C "${STAGE}" -czf "${OUT}" bin migrations otel-collector.yaml BUILD_INFO SHA256SUMS
