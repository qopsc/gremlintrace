#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  STUB_BIN="${TEST_TMPDIR}/bin"
  mkdir -p "${STUB_BIN}"

  cat >"${STUB_BIN}/file" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"/bin/api"*|*"/bin/envd"*|*"/bin/goose"*|*"/bin/client-proxy"*|*"/bin/e2b-seed"*)
    echo "ELF 64-bit LSB executable, x86-64, statically linked, not stripped"
    ;;
  *"/bin/orchestrator"*)
    echo "ELF 64-bit LSB executable, x86-64, dynamically linked, not stripped"
    ;;
  *)
    echo "data"
    ;;
esac
EOF
  chmod +x "${STUB_BIN}/file"

  cat >"${STUB_BIN}/ldd" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *orchestrator* ]]; then
  echo "libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6"
fi
EOF
  chmod +x "${STUB_BIN}/ldd"

  export PATH="${STUB_BIN}:${PATH}"
  VERSIONS_FILE="${REPO_ROOT}/versions.yml"
  VALIDATE_SH="${REPO_ROOT}/ci/validate-e2b-dist.sh"
}

teardown() {
  /bin/rm -rf "${TEST_TMPDIR}"
}

build_fixture_tarball() {
  local migration_ts="$1"
  local api_embed_ts="$2"
  local build_info_ts="$3"
  local stage="${TEST_TMPDIR}/stage-$$"
  local tarball="${TEST_TMPDIR}/fixture-$$.tar.gz"
  local pin
  pin="$(python3 "${REPO_ROOT}/ci/yaml_versions.py" get e2b_pin "${VERSIONS_FILE}")"

  mkdir -p "${stage}/bin" "${stage}/migrations/postgres"
  printf '%s_init.sql\n' "${migration_ts}" >"${stage}/migrations/postgres/${migration_ts}_init.sql"

  for bin in orchestrator client-proxy envd e2b-seed goose; do
    printf 'stub-%s\n' "${bin}" >"${stage}/bin/${bin}"
    chmod +x "${stage}/bin/${bin}"
  done
  {
    printf 'prefix-%s-suffix\n' "${api_embed_ts}"
    printf '%s\n' "${api_embed_ts}"
  } >"${stage}/bin/api"
  chmod +x "${stage}/bin/api"

  cat >"${stage}/BUILD_INFO" <<EOF
{
  "e2b_pin": "${pin}",
  "expected_migration_timestamp": "${build_info_ts}",
  "clean_nfs_cache": false
}
EOF

  (
    cd "${stage}"
    find . -type f ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort | while IFS= read -r f; do
      sha256sum "${f}"
    done
  ) >"${stage}/SHA256SUMS"

  tar -C "${stage}" -czf "${tarball}" .
  /bin/rm -rf "${stage}"
  printf '%s\n' "${tarball}"
}

@test "validate-e2b-dist accepts fixture when api, BUILD_INFO, and migrations agree" {
  local tarball
  tarball="$(build_fixture_tarball "20240101120000" "20240101120000" "20240101120000")"
  run "${VALIDATE_SH}" --tarball "${tarball}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"validate-e2b-dist: ok"* ]]
}

@test "validate-e2b-dist rejects api binary with mismatched migration timestamp" {
  local tarball
  tarball="$(build_fixture_tarball "20240101120000" "20240101120001" "20240101120000")"
  run "${VALIDATE_SH}" --tarball "${tarball}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"api binary expectedMigrationTimestamp 20240101120001"* ]]
}

@test "validate-e2b-dist rejects when api migration timestamp cannot be extracted" {
  local tarball stage pin
  stage="${TEST_TMPDIR}/stage-no-ts"
  tarball="${TEST_TMPDIR}/no-ts.tar.gz"
  pin="$(python3 "${REPO_ROOT}/ci/yaml_versions.py" get e2b_pin "${VERSIONS_FILE}")"
  mkdir -p "${stage}/bin" "${stage}/migrations/postgres"
  printf '20240101120000_init.sql\n' >"${stage}/migrations/postgres/20240101120000_init.sql"
  for bin in orchestrator api client-proxy envd e2b-seed goose; do
    printf 'no-timestamp\n' >"${stage}/bin/${bin}"
    chmod +x "${stage}/bin/${bin}"
  done
  cat >"${stage}/BUILD_INFO" <<EOF
{"e2b_pin":"${pin}","expected_migration_timestamp":"20240101120000","clean_nfs_cache":false}
EOF
  (cd "${stage}" && find . -type f ! -name SHA256SUMS -printf '%P\n' | while read -r f; do sha256sum "${f}"; done) >"${stage}/SHA256SUMS"
  tar -C "${stage}" -czf "${tarball}" .
  run "${VALIDATE_SH}" --tarball "${tarball}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not extract expectedMigrationTimestamp"* ]]
}

@test "stage-release stages dist and packed mirrored tarballs only" {
  local artifacts upload dist mirrored packed
  artifacts="${TEST_TMPDIR}/artifacts"
  upload="${TEST_TMPDIR}/upload"
  dist="${TEST_TMPDIR}/e2b-dist.tar.gz"
  printf 'dist\n' >"${dist}"
  "${REPO_ROOT}/ci/mirror-e2b-artifacts.sh" --out "${artifacts}"
  packed="${TEST_TMPDIR}/e2b-fc-artifacts.tar.gz"
  "${REPO_ROOT}/ci/pack-mirrored-artifacts.sh" --artifacts "${artifacts}" --out "${packed}"
  run "${REPO_ROOT}/ci/stage-release.sh" \
    --dist-tarball "${dist}" \
    --mirrored-tarball "${packed}" \
    --upload-dir "${upload}"
  [ "$status" -eq 0 ]
  [ -f "${upload}/e2b-dist.tar.gz" ]
  [ -f "${upload}/e2b-fc-artifacts.tar.gz" ]
  [ -f "${upload}/e2b-fc-artifacts.tar.gz.sha256" ]
  [ "$(find "${upload}" -mindepth 1 -maxdepth 1 | wc -l)" -eq 3 ]
}
