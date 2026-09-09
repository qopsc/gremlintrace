#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  BUMP_SH="${REPO_ROOT}/ci/bump-e2b-pin.sh"
}

teardown() {
  /bin/rm -rf "${TEST_TMPDIR}"
}

@test "pin bump parses and updates upstream artifact pins" {
  local fake_repo upstream curl_stub versions pin latest expected_fc expected_kernel expected_busybox
  fake_repo="${TEST_TMPDIR}/repo"
  upstream="${TEST_TMPDIR}/upstream"
  curl_stub="${TEST_TMPDIR}/curl"
  versions="${fake_repo}/versions.yml"
  pin="${fake_repo}/e2b/e2b.pin"

  mkdir -p "${fake_repo}/ci" "${fake_repo}/e2b" "${upstream}/packages/shared/pkg/featureflags" \
    "${upstream}/packages/orchestrator/pkg/cfg" "${upstream}/packages/envd/pkg" "${upstream}/packages/db"
  cp "${BUMP_SH}" "${fake_repo}/ci/bump-e2b-pin.sh"
  cp "${REPO_ROOT}/ci/yaml_versions.py" "${fake_repo}/ci/yaml_versions.py"
  cp "${REPO_ROOT}/versions.yml" "${versions}"
  cp "${REPO_ROOT}/e2b/e2b.pin" "${pin}"
  chmod +x "${fake_repo}/ci/bump-e2b-pin.sh"

  cat >"${upstream}/packages/shared/pkg/featureflags/flags.go" <<'EOF'
package featureflags

const DefaultKernelVersion = "test-kernel"

const (
	DefaultFirecrackerV1_14_0Version = "test-firecracker"
	DefaultFirecrackerVersion = DefaultFirecrackerV1_14_0Version
)
EOF
  cat >"${upstream}/packages/orchestrator/pkg/cfg/model.go" <<'EOF'
package cfg

const DefaultBusyboxVersion = "test-busybox"
EOF
  printf 'package pkg\n\nconst Version = "9.9.9"\n' >"${upstream}/packages/envd/pkg/version.go"
  printf 'module example/db\n\ngo 9.9.9\n\nrequire (\n\tgithub.com/pressly/goose/v3 v3.99.0\n)\n' >"${upstream}/packages/db/go.mod"
  printf 'go 9.9.9\n' >"${upstream}/go.work"

  git -C "${upstream}" init -q
  git -C "${upstream}" add .
  git -C "${upstream}" -c user.name=test -c user.email=test@example.invalid commit -q -m fixture
  latest="$(git -C "${upstream}" rev-parse HEAD)"

  cat >"${curl_stub}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) url="$1"; shift ;;
  esac
done
case "${url}" in
  *firecrackers/test-firecracker/*) printf 'new-firecracker\n' >"${out}" ;;
  *kernels/test-kernel/*) printf 'new-kernel\n' >"${out}" ;;
  *busybox/test-busybox/*) printf 'new-busybox\n' >"${out}" ;;
  *) echo "unexpected URL: ${url}" >&2; exit 1 ;;
esac
EOF
  chmod +x "${curl_stub}"

  run env \
    E2B_UPSTREAM_URL="file://${upstream}" \
    E2B_CURL="${curl_stub}" \
    "${fake_repo}/ci/bump-e2b-pin.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"${latest}"* ]]
  [ "$(cat "${pin}")" = "${latest}" ]
  [ "$(python3 "${fake_repo}/ci/yaml_versions.py" get e2b_pin "${versions}")" = "${latest}" ]
  [ "$(python3 "${fake_repo}/ci/yaml_versions.py" get firecracker_version "${versions}")" = "test-firecracker" ]
  [ "$(python3 "${fake_repo}/ci/yaml_versions.py" get kernel_version "${versions}")" = "test-kernel" ]
  [ "$(python3 "${fake_repo}/ci/yaml_versions.py" get busybox_version "${versions}")" = "test-busybox" ]
  expected_fc="$(printf 'new-firecracker\n' | sha256sum | awk '{print $1}')"
  expected_kernel="$(printf 'new-kernel\n' | sha256sum | awk '{print $1}')"
  expected_busybox="$(printf 'new-busybox\n' | sha256sum | awk '{print $1}')"
  [ "$(python3 "${fake_repo}/ci/yaml_versions.py" get firecracker_sha256 "${versions}")" = "${expected_fc}" ]
  [ "$(python3 "${fake_repo}/ci/yaml_versions.py" get kernel_sha256 "${versions}")" = "${expected_kernel}" ]
  [ "$(python3 "${fake_repo}/ci/yaml_versions.py" get busybox_sha256 "${versions}")" = "${expected_busybox}" ]
}
