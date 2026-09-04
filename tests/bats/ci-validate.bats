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
  "clean_nfs_cache": false,
  "patches": [{
    "filename": "0001-force-stop-marker.patch",
    "sha256": "ee6e4144cd1ae5a5ff6219a2c68fe90a3e893bb28a06cc8dd9bc30004e2789fa"
  }]
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
{"e2b_pin":"${pin}","expected_migration_timestamp":"20240101120000","clean_nfs_cache":false,"patches":[{"filename":"0001-force-stop-marker.patch","sha256":"ee6e4144cd1ae5a5ff6219a2c68fe90a3e893bb28a06cc8dd9bc30004e2789fa"}]}
EOF
  (cd "${stage}" && find . -type f ! -name SHA256SUMS -printf '%P\n' | while read -r f; do sha256sum "${f}"; done) >"${stage}/SHA256SUMS"
  tar -C "${stage}" -czf "${tarball}" .
  run "${VALIDATE_SH}" --tarball "${tarball}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not extract expectedMigrationTimestamp"* ]]
}

@test "stage-release stages dist, checksums, and packed mirrored tarballs" {
  local artifacts upload dist mirrored packed fc_ver kernel_ver busybox_ver
  artifacts="${TEST_TMPDIR}/artifacts"
  upload="${TEST_TMPDIR}/upload"
  dist="${TEST_TMPDIR}/e2b-dist.tar.gz"
  printf 'dist\n' >"${dist}"
  fc_ver="$(python3 "${REPO_ROOT}/ci/yaml_versions.py" get firecracker_version "${VERSIONS_FILE}")"
  kernel_ver="$(python3 "${REPO_ROOT}/ci/yaml_versions.py" get kernel_version "${VERSIONS_FILE}")"
  busybox_ver="$(python3 "${REPO_ROOT}/ci/yaml_versions.py" get busybox_version "${VERSIONS_FILE}")"
  mkdir -p \
    "${artifacts}/firecrackers/${fc_ver}/amd64" \
    "${artifacts}/kernels/${kernel_ver}/amd64" \
    "${artifacts}/busybox/${busybox_ver}/amd64"
  printf 'fc\n' >"${artifacts}/firecrackers/${fc_ver}/amd64/firecracker"
  printf 'kernel\n' >"${artifacts}/kernels/${kernel_ver}/amd64/vmlinux.bin"
  printf 'busybox\n' >"${artifacts}/busybox/${busybox_ver}/amd64/busybox"
  printf '%s  busybox\n' "$(sha256sum "${artifacts}/busybox/${busybox_ver}/amd64/busybox" | awk '{print $1}')" \
    >"${artifacts}/busybox/${busybox_ver}/amd64/busybox.sha256"
  packed="${TEST_TMPDIR}/e2b-fc-artifacts.tar.gz"
  "${REPO_ROOT}/ci/pack-mirrored-artifacts.sh" --artifacts "${artifacts}" --out "${packed}"
  run "${REPO_ROOT}/ci/stage-release.sh" \
    --dist-tarball "${dist}" \
    --mirrored-tarball "${packed}" \
    --upload-dir "${upload}"
  [ "$status" -eq 0 ]
  [ -f "${upload}/e2b-dist.tar.gz" ]
  [ -f "${upload}/e2b-dist.tar.gz.sha256" ]
  [ -f "${upload}/e2b-fc-artifacts.tar.gz" ]
  [ -f "${upload}/e2b-fc-artifacts.tar.gz.sha256" ]
  run bash -c 'cd "$1" && sha256sum -c "$(basename "$2").sha256"' bash "${upload}" "${upload}/e2b-dist.tar.gz"
  [ "$status" -eq 0 ]
  [ "$(find "${upload}" -mindepth 1 -maxdepth 1 | wc -l)" -eq 4 ]
}
