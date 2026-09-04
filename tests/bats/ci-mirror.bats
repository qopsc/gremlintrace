#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  STUB_BIN="${TEST_TMPDIR}/bin"
  mkdir -p "${STUB_BIN}"

  export CURL_STUB_LOG="${TEST_TMPDIR}/curl.log"
  : >"${CURL_STUB_LOG}"

  cat >"${STUB_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CURL_STUB_LOG}"
code="${MIRROR_STUB_HTTP_CODE:-200}"
outfile=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      outfile="$2"
      shift 2
      ;;
    -w)
      shift 2
      ;;
    -f|-s|-S|-L)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done
if [[ "${code}" != "200" ]]; then
  [[ -z "${outfile}" ]] || rm -f "${outfile}"
  printf '%s' "${code}"
  exit 0
fi
if [[ -n "${outfile}" ]]; then
  case "${url}" in
    *busybox.sha256*)
      if [[ "${MIRROR_STUB_BAD_BUSYBOX_SHA:-}" == "1" ]]; then
        printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef  busybox\n' >"${outfile}"
      else
        printf '%s  busybox\n' "$(printf '%s' "${MIRROR_STUB_BUSYBOX_BYTES:-busybox-bytes}" | sha256sum | awk '{print $1}')" >"${outfile}"
      fi
      ;;
    *busybox*)
      printf '%s' "${MIRROR_STUB_BUSYBOX_BYTES:-busybox-bytes}" >"${outfile}"
      ;;
    *firecracker*)
      printf 'fc-bytes' >"${outfile}"
      ;;
    *vmlinux*)
      printf 'kernel-bytes' >"${outfile}"
      ;;
    *)
      printf 'unknown-url:%s\n' "${url}" >&2
      exit 1
      ;;
  esac
fi
printf '%s' "${code}"
EOF
  chmod +x "${STUB_BIN}/curl"

  export PATH="${STUB_BIN}:${PATH}"
  VERSIONS_FILE="${TEST_TMPDIR}/versions.yml"
  cp "${REPO_ROOT}/versions.yml" "${VERSIONS_FILE}"
  fc_sha="$(printf 'fc-bytes' | sha256sum | awk '{print $1}')"
  kernel_sha="$(printf 'kernel-bytes' | sha256sum | awk '{print $1}')"
  busybox_sha="$(printf '%s' "${MIRROR_STUB_BUSYBOX_BYTES:-busybox-bytes}" | sha256sum | awk '{print $1}')"
  sed -i.bak \
    -e "s/^firecracker_sha256:.*/firecracker_sha256: \"${fc_sha}\"/" \
    -e "s/^kernel_sha256:.*/kernel_sha256: \"${kernel_sha}\"/" \
    -e "s/^busybox_sha256:.*/busybox_sha256: \"${busybox_sha}\"/" \
    "${VERSIONS_FILE}"
  rm -f "${VERSIONS_FILE}.bak"
}

teardown() {
  /bin/rm -rf "${TEST_TMPDIR}"
}

@test "mirror-e2b-artifacts succeeds and lays out fc/config.go paths" {
  local out
  out="${TEST_TMPDIR}/artifacts"
  run "${REPO_ROOT}/ci/mirror-e2b-artifacts.sh" --versions "${VERSIONS_FILE}" --out "${out}"
  [ "$status" -eq 0 ]
  run python3 - "${out}" "${VERSIONS_FILE}" "${REPO_ROOT}" <<'PY'
import sys
from pathlib import Path
import subprocess

out = Path(sys.argv[1])
versions = Path(sys.argv[2])
repo = Path(sys.argv[3])
get = lambda k: subprocess.check_output(
    ["python3", str(repo / "ci/yaml_versions.py"), "get", k, str(versions)], text=True
).strip()

fc = out / "firecrackers" / get("firecracker_version") / "amd64" / "firecracker"
kernel = out / "kernels" / get("kernel_version") / "amd64" / "vmlinux.bin"
busybox = out / "busybox" / get("busybox_version") / "amd64" / "busybox"
for path in (fc, kernel, busybox):
    if not path.is_file():
        raise SystemExit(f"missing {path}")
manifest = out / "artifacts-SHA256SUMS"
if not manifest.is_file():
    raise SystemExit("missing artifacts-SHA256SUMS")
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "mirror-e2b-artifacts preserves an existing output tree on HTTP 404" {
  local out
  out="${TEST_TMPDIR}/artifacts-404"
  mkdir -p "${out}"
  printf 'keep me\n' >"${out}/sentinel"
  export MIRROR_STUB_HTTP_CODE="404"
  run "${REPO_ROOT}/ci/mirror-e2b-artifacts.sh" --versions "${VERSIONS_FILE}" --out "${out}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"download failed (404)"* ]]
  [ -f "${out}/sentinel" ]
}

@test "mirror-e2b-artifacts fails closed on busybox checksum mismatch" {
  local out
  out="${TEST_TMPDIR}/artifacts-bad-sha"
  export MIRROR_STUB_BAD_BUSYBOX_SHA="1"
  run "${REPO_ROOT}/ci/mirror-e2b-artifacts.sh" --versions "${VERSIONS_FILE}" --out "${out}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED"* || "$output" == *"sha256sum"* ]]
  [ ! -e "${out}/firecrackers" ]
}

@test "pack-mirrored-artifacts preserves hierarchy inside tarball" {
  local artifacts packed extract
  artifacts="${TEST_TMPDIR}/artifacts"
  packed="${TEST_TMPDIR}/e2b-fc-artifacts-test.tar.gz"
  extract="${TEST_TMPDIR}/extract"
  "${REPO_ROOT}/ci/mirror-e2b-artifacts.sh" --versions "${VERSIONS_FILE}" --out "${artifacts}"
  run "${REPO_ROOT}/ci/pack-mirrored-artifacts.sh" --artifacts "${artifacts}" --out "${packed}"
  [ "$status" -eq 0 ]
  run bash -c 'cd "$1" && sha256sum -c "$(basename "$2").sha256"' bash "$(dirname "${packed}")" "${packed}"
  [ "$status" -eq 0 ]
  mkdir -p "${extract}"
  tar -xzf "${packed}" -C "${extract}"
  run python3 - "${extract}" "${VERSIONS_FILE}" "${REPO_ROOT}" <<'PY'
import sys
from pathlib import Path
import subprocess

root = Path(sys.argv[1])
versions = Path(sys.argv[2])
repo = Path(sys.argv[3])
get = lambda k: subprocess.check_output(
    ["python3", str(repo / "ci/yaml_versions.py"), "get", k, str(versions)], text=True
).strip()

paths = [
    root / "firecrackers" / get("firecracker_version") / "amd64" / "firecracker",
    root / "kernels" / get("kernel_version") / "amd64" / "vmlinux.bin",
    root / "busybox" / get("busybox_version") / "amd64" / "busybox",
    root / "SHA256SUMS",
]
for path in paths:
    if not path.exists():
        raise SystemExit(f"missing {path}")
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}
