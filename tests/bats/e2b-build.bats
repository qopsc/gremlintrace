#!/usr/bin/env bats

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  STUB_BIN="${TEST_TMPDIR}/bin"
  mkdir -p "${STUB_BIN}"

  export DOCKER_STUB_LOG="${TEST_TMPDIR}/docker.log"
  export GIT_STUB_LOG="${TEST_TMPDIR}/git.log"
  export GIT_APPLY_LOG="${TEST_TMPDIR}/git-apply.log"
  : >"${DOCKER_STUB_LOG}"
  : >"${GIT_STUB_LOG}"
  : >"${GIT_APPLY_LOG}"

  cat >"${STUB_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${DOCKER_STUB_LOG}"
exit 0
EOF
  chmod +x "${STUB_BIN}/docker"

  cat >"${STUB_BIN}/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GIT_STUB_LOG}"
args=("$@")
i=0
while (( i < ${#args[@]} )); do
  if [[ "${args[i]}" == "-C" ]]; then
    i=$((i + 2))
    continue
  fi
  break
done
cmd="${args[i]:-}"
case "${cmd}" in
  rev-parse)
    printf '%s\n' "${GIT_STUB_HEAD:?GIT_STUB_HEAD is unset}"
    ;;
  apply)
    patch="${args[$((${#args[@]} - 1))]}"
    base="$(basename "${patch}")"
    printf '%s\n' "${base}" >>"${GIT_APPLY_LOG}"
    if [[ -n "${GIT_APPLY_FAIL:-}" && "${base}" == "${GIT_APPLY_FAIL}" ]]; then
      printf 'error: patch does not apply: %s\n' "${base}" >&2
      exit 1
    fi
    ;;
  *)
    printf 'unexpected git command: %s\n' "${cmd}" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "${STUB_BIN}/git"

  export PATH="${STUB_BIN}:${PATH}"
  export DOCKER="${STUB_BIN}/docker"
  export GIT="${STUB_BIN}/git"

  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  BUILD_SH="${REPO_ROOT}/e2b/build/build.sh"
  VERSIONS_FILE="${REPO_ROOT}/versions.yml"
  E2B_PIN_FILE="${REPO_ROOT}/e2b/e2b.pin"
}

teardown() {
  /bin/rm -rf "${TEST_TMPDIR}"
}

write_versions_fixture() {
  local dest="$1"
  shift
  python3 -c '
import sys
import yaml

src, dest = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as fh:
    data = yaml.safe_load(fh)
for item in sys.argv[3:]:
    key, value = item.split("=", 1)
    data[key] = value
with open(dest, "w", encoding="utf-8") as fh:
    yaml.safe_dump(data, fh, default_flow_style=False, sort_keys=False)
' "${VERSIONS_FILE}" "${dest}" "$@"
}

fixture_go_version() {
  python3 -c '
import sys
import yaml
print(yaml.safe_load(open(sys.argv[1], encoding="utf-8"))["e2b_go_version"])
' "$1"
}

write_gowork() {
  local src="$1"
  local ver="$2"
  mkdir -p "${src}"
  printf 'go %s\n' "${ver}" >"${src}/go.work"
}

@test "build.sh aborts when e2b.pin and versions.yml e2b_pin disagree" {
  local versions pin
  versions="${TEST_TMPDIR}/versions.yml"
  pin="${TEST_TMPDIR}/e2b.pin"
  cp "${VERSIONS_FILE}" "${versions}"
  printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" >"${pin}"

  run "${BUILD_SH}" --dry-run --versions "${versions}" --pin-file "${pin}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match"* ]]
  [ ! -s "${DOCKER_STUB_LOG}" ]
}

@test "--dry-run prints pin, Go version, and tarball name from versions.yml" {
  local versions_a pin_a versions_b pin_b
  versions_a="${TEST_TMPDIR}/versions-a.yml"
  versions_b="${TEST_TMPDIR}/versions-b.yml"
  pin_a="${TEST_TMPDIR}/pin-a"
  pin_b="${TEST_TMPDIR}/pin-b"

  write_versions_fixture "${versions_a}" \
    "e2b_pin=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    "e2b_dist_version=aaaaaaa" \
    "e2b_go_version=9.99.99"
  printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" >"${pin_a}"

  write_versions_fixture "${versions_b}" \
    "e2b_pin=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    "e2b_dist_version=bbbbbbb" \
    "e2b_go_version=8.88.88"
  printf '%s\n' "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" >"${pin_b}"

  run "${BUILD_SH}" --dry-run --versions "${versions_a}" --pin-file "${pin_a}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"e2b_pin=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"* ]]
  [[ "$output" == *"e2b_go_version=9.99.99"* ]]
  [[ "$output" == *"tarball=e2b-aaaaaaa.tar.gz"* ]]
  [[ "$output" != *"e2b_go_version=8.88.88"* ]]
  [[ "$output" != *"tarball=e2b-bbbbbbb.tar.gz"* ]]
  [ ! -s "${DOCKER_STUB_LOG}" ]

  run "${BUILD_SH}" --dry-run --versions "${versions_b}" --pin-file "${pin_b}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"e2b_pin=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"* ]]
  [[ "$output" == *"e2b_go_version=8.88.88"* ]]
  [[ "$output" == *"tarball=e2b-bbbbbbb.tar.gz"* ]]
  [[ "$output" != *"e2b_go_version=9.99.99"* ]]
  [[ "$output" != *"tarball=e2b-aaaaaaa.tar.gz"* ]]
  [ ! -s "${DOCKER_STUB_LOG}" ]
}

@test "patch loop applies patches in lexical order" {
  local versions pin patches src dist
  versions="${TEST_TMPDIR}/versions.yml"
  pin="${TEST_TMPDIR}/e2b.pin"
  cp "${VERSIONS_FILE}" "${versions}"
  cp "${E2B_PIN_FILE}" "${pin}"
  export GIT_STUB_HEAD
  GIT_STUB_HEAD="$(tr -d '[:space:]' <"${pin}")"

  patches="${TEST_TMPDIR}/patches"
  mkdir -p "${patches}"
  printf 'diff --git a/x b/x\n' >"${patches}/0002-second.patch"
  printf 'diff --git a/x b/x\n' >"${patches}/0001-first.patch"

  src="${TEST_TMPDIR}/src"
  mkdir -p "${src}"
  write_gowork "${src}" "$(fixture_go_version "${versions}")"
  dist="${TEST_TMPDIR}/dist"

  run "${BUILD_SH}" \
    --src "${src}" \
    --versions "${versions}" \
    --pin-file "${pin}" \
    --patches "${patches}" \
    --dist "${dist}"
  [ "$status" -eq 0 ]
  [ -s "${GIT_APPLY_LOG}" ]
  run cat "${GIT_APPLY_LOG}"
  [ "$output" = $'0001-first.patch\n0002-second.patch' ]
}

@test "patch loop fails the build when a patch does not apply" {
  local versions pin patches src dist
  versions="${TEST_TMPDIR}/versions.yml"
  pin="${TEST_TMPDIR}/e2b.pin"
  cp "${VERSIONS_FILE}" "${versions}"
  cp "${E2B_PIN_FILE}" "${pin}"
  export GIT_STUB_HEAD
  GIT_STUB_HEAD="$(tr -d '[:space:]' <"${pin}")"
  export GIT_APPLY_FAIL="0002-second.patch"

  patches="${TEST_TMPDIR}/patches"
  mkdir -p "${patches}"
  printf 'diff --git a/x b/x\n' >"${patches}/0001-first.patch"
  printf 'diff --git a/x b/x\n' >"${patches}/0002-second.patch"

  src="${TEST_TMPDIR}/src"
  mkdir -p "${src}"
  dist="${TEST_TMPDIR}/dist"

  run "${BUILD_SH}" \
    --src "${src}" \
    --versions "${versions}" \
    --pin-file "${pin}" \
    --patches "${patches}" \
    --dist "${dist}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"0002-second.patch"* ]]
  [[ "$output" == *"patch failed to apply"* ]]
  [ ! -s "${DOCKER_STUB_LOG}" ]
  run cat "${GIT_APPLY_LOG}"
  [ "$output" = $'0001-first.patch\n0002-second.patch' ]
}

@test "empty patches directory succeeds and does not apply a literal *.patch" {
  local versions pin patches src dist
  versions="${TEST_TMPDIR}/versions.yml"
  pin="${TEST_TMPDIR}/e2b.pin"
  cp "${VERSIONS_FILE}" "${versions}"
  cp "${E2B_PIN_FILE}" "${pin}"
  export GIT_STUB_HEAD
  GIT_STUB_HEAD="$(tr -d '[:space:]' <"${pin}")"

  patches="${TEST_TMPDIR}/patches"
  mkdir -p "${patches}"
  printf '# not a patch\n' >"${patches}/README.md"

  src="${TEST_TMPDIR}/src"
  mkdir -p "${src}"
  write_gowork "${src}" "$(fixture_go_version "${versions}")"
  dist="${TEST_TMPDIR}/dist"

  run "${BUILD_SH}" \
    --src "${src}" \
    --versions "${versions}" \
    --pin-file "${pin}" \
    --patches "${patches}" \
    --dist "${dist}"
  [ "$status" -eq 0 ]
  if grep -F '*.patch' "${GIT_STUB_LOG}" "${GIT_APPLY_LOG}"; then
    echo "literal *.patch was passed to git" >&2
    cat "${GIT_STUB_LOG}" >&2
    return 1
  fi
  [ ! -s "${GIT_APPLY_LOG}" ]
  [ -s "${DOCKER_STUB_LOG}" ]
}

@test "build.sh aborts when yaml_versions helper is missing" {
  local fake_root versions pin
  fake_root="${TEST_TMPDIR}/fake-repo"
  mkdir -p "${fake_root}/e2b/build" "${fake_root}/ci" "${fake_root}/e2b"
  cp "${BUILD_SH}" "${fake_root}/e2b/build/build.sh"
  cp "${VERSIONS_FILE}" "${fake_root}/versions.yml"
  cp "${E2B_PIN_FILE}" "${fake_root}/e2b/e2b.pin"
  versions="${fake_root}/versions.yml"
  pin="${fake_root}/e2b/e2b.pin"
  run "${fake_root}/e2b/build/build.sh" --dry-run --versions "${versions}" --pin-file "${pin}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"yaml_versions helper not found"* ]]
}

@test "build.sh aborts when versions.yml key is missing" {
  local versions pin
  versions="${TEST_TMPDIR}/versions-missing-key.yml"
  pin="${TEST_TMPDIR}/e2b.pin"
  grep -v '^e2b_pin:' "${VERSIONS_FILE}" >"${versions}"
  cp "${E2B_PIN_FILE}" "${pin}"
  run "${BUILD_SH}" --dry-run --versions "${versions}" --pin-file "${pin}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing key"* ]]
}

@test "--dry-run does not invoke Docker" {
  run "${BUILD_SH}" --dry-run
  [ "$status" -eq 0 ]
  [ ! -s "${DOCKER_STUB_LOG}" ]
  run cat "${DOCKER_STUB_LOG}"
  [ -z "$output" ]
}

@test "Dockerfile.build contains no hard-coded Go version" {
  local dockerfile="${REPO_ROOT}/e2b/build/Dockerfile.build"
  grep -q 'ARG GO_VERSION' "${dockerfile}"
  grep -qF 'FROM golang:${GO_VERSION}-bookworm' "${dockerfile}"
  grep -q 'GOTOOLCHAIN=local' "${dockerfile}"
  if grep -E 'golang:[0-9]|ARG[[:space:]]+GO_VERSION=' "${dockerfile}"; then
    echo "hard-coded Go version found in Dockerfile.build" >&2
    return 1
  fi
}

@test "go.work matching e2b_go_version (same major.minor, pin >= directive) passes" {
  local versions pin patches src dist
  versions="${TEST_TMPDIR}/versions.yml"
  pin="${TEST_TMPDIR}/e2b.pin"
  write_versions_fixture "${versions}" \
    "e2b_pin=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    "e2b_dist_version=aaaaaaa" \
    "e2b_go_version=9.99.99"
  printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" >"${pin}"
  export GIT_STUB_HEAD="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  patches="${TEST_TMPDIR}/patches"
  mkdir -p "${patches}"
  src="${TEST_TMPDIR}/src"
  # go 9.99 (no patch) must be accepted by pin 9.99.99 — not exact-string equality.
  write_gowork "${src}" "9.99"
  dist="${TEST_TMPDIR}/dist"

  run "${BUILD_SH}" \
    --src "${src}" \
    --versions "${versions}" \
    --pin-file "${pin}" \
    --patches "${patches}" \
    --dist "${dist}"
  [ "$status" -eq 0 ]
  [ -s "${DOCKER_STUB_LOG}" ]
  grep -q 'GOTOOLCHAIN=local' "${DOCKER_STUB_LOG}"
}

@test "go.work that differs from e2b_go_version aborts and names both versions" {
  local versions pin patches src dist
  versions="${TEST_TMPDIR}/versions.yml"
  pin="${TEST_TMPDIR}/e2b.pin"
  write_versions_fixture "${versions}" \
    "e2b_pin=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    "e2b_dist_version=aaaaaaa" \
    "e2b_go_version=9.99.99"
  printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" >"${pin}"
  export GIT_STUB_HEAD="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  patches="${TEST_TMPDIR}/patches"
  mkdir -p "${patches}"
  src="${TEST_TMPDIR}/src"
  write_gowork "${src}" "8.88.88"
  dist="${TEST_TMPDIR}/dist"

  run "${BUILD_SH}" \
    --src "${src}" \
    --versions "${versions}" \
    --pin-file "${pin}" \
    --patches "${patches}" \
    --dist "${dist}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"9.99.99"* ]]
  [[ "$output" == *"8.88.88"* ]]
  [[ "$output" == *"update versions.yml"* ]]
  [ ! -s "${DOCKER_STUB_LOG}" ]
}

@test "go.work patch newer than e2b_go_version aborts (pin does not satisfy minimum)" {
  local versions pin patches src dist
  versions="${TEST_TMPDIR}/versions.yml"
  pin="${TEST_TMPDIR}/e2b.pin"
  write_versions_fixture "${versions}" \
    "e2b_pin=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    "e2b_dist_version=aaaaaaa" \
    "e2b_go_version=9.99.99"
  printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" >"${pin}"
  export GIT_STUB_HEAD="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  patches="${TEST_TMPDIR}/patches"
  mkdir -p "${patches}"
  src="${TEST_TMPDIR}/src"
  write_gowork "${src}" "9.99.100"
  dist="${TEST_TMPDIR}/dist"

  run "${BUILD_SH}" \
    --src "${src}" \
    --versions "${versions}" \
    --pin-file "${pin}" \
    --patches "${patches}" \
    --dist "${dist}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"9.99.99"* ]]
  [[ "$output" == *"9.99.100"* ]]
  [ ! -s "${DOCKER_STUB_LOG}" ]
}
