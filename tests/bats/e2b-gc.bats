#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  GC="${REPO_ROOT}/ansible/roles/backup/files/qops-e2b-gc"
  STORE="${BATS_TMPDIR}/store"
  rm -rf "${STORE}"
  mkdir -p "${STORE}"
  NOW=1700000000
}

disable_guard() {
  local name="$1"
  local dest="$2"
  python3 - "${GC}" "${name}" "${dest}" <<'PY'
import re
import sys

src, name, dest = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src, encoding="utf-8").read()
pattern = rf"[ \t]*# BEGIN_GUARD {re.escape(name)}\n.*?# END_GUARD {re.escape(name)}\n"
new, count = re.subn(pattern, f"        # GUARD {name} DISABLED\n", text, count=1, flags=re.S)
if count != 1:
    raise SystemExit(f"guard {name!r} not found or not unique ({count})")
open(dest, "w", encoding="utf-8").write(new)
PY
}

make_dir() {
  local name="$1"
  local mtime="$2"
  mkdir -p "${STORE}/${name}"
  printf 'blob\n' >"${STORE}/${name}/memfile"
  touch -d "@${mtime}" "${STORE}/${name}"
}

query_file() {
  printf '%s\n' "$@"
}

run_gc() {
  local script="${1:-${GC}}"
  shift || true
  python3 "${script}" \
    --store "${STORE}" \
    --retention-hours 24 \
    --now-epoch "${NOW}" \
    --docker-bin /bin/false \
    --summary-path "${BATS_TMPDIR}/missing-summary.json" \
    "$@"
}

@test "referenced build is never deleted" {
  make_dir live-build $((NOW - 1000000))
  make_dir old-unref $((NOW - 1000000))
  qf="${BATS_TMPDIR}/query.sh"
  cat >"${qf}" <<EOF
#!/usr/bin/env bash
printf '%s\n' live-build __QOPS_E2B_GC_QUERY_OK__
EOF
  chmod +x "${qf}"
  run run_gc "${GC}" --query-cmd "${qf}"
  [ "$status" -eq 0 ]
  [ -d "${STORE}/live-build" ]
  [ ! -d "${STORE}/old-unref" ]
}

@test "referenced-build test fails if the keep_referenced guard is removed" {
  make_dir live-build $((NOW - 1000000))
  mutated="${BATS_TMPDIR}/gc-no-ref.py"
  disable_guard keep_referenced "${mutated}"
  qf="${BATS_TMPDIR}/query-ref.sh"
  cat >"${qf}" <<'EOF'
#!/usr/bin/env bash
state_file="${QOPS_GC_QUERY_STATE}"
n="$(cat "${state_file}")"
n="$((n + 1))"
printf '%s\n' "${n}" >"${state_file}"
if [[ "${n}" -eq 1 ]]; then
  printf '%s\n' live-build __QOPS_E2B_GC_QUERY_OK__
  exit 0
fi
printf '%s\n' __QOPS_E2B_GC_QUERY_OK__
EOF
  chmod +x "${qf}"
  export QOPS_GC_QUERY_STATE="${BATS_TMPDIR}/ref.state"
  printf '0\n' >"${QOPS_GC_QUERY_STATE}"
  run run_gc "${mutated}" --query-cmd "${qf}"
  [ "$status" -eq 0 ]
  [ ! -d "${STORE}/live-build" ]
}

@test "unreferenced build newer than retention is kept" {
  make_dir fresh-unref $((NOW - 60))
  qf="${BATS_TMPDIR}/query-empty.sh"
  cat >"${qf}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' __QOPS_E2B_GC_QUERY_OK__
EOF
  chmod +x "${qf}"
  run run_gc "${GC}" --query-cmd "${qf}"
  [ "$status" -eq 0 ]
  [ -d "${STORE}/fresh-unref" ]
}

@test "fresh-unref test fails if the retention guard is removed" {
  make_dir fresh-unref $((NOW - 60))
  mutated="${BATS_TMPDIR}/gc-no-ret.py"
  disable_guard retention "${mutated}"
  qf="${BATS_TMPDIR}/query-empty2.sh"
  cat >"${qf}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' __QOPS_E2B_GC_QUERY_OK__
EOF
  chmod +x "${qf}"
  run run_gc "${mutated}" --query-cmd "${qf}"
  [ "$status" -eq 0 ]
  [ ! -d "${STORE}/fresh-unref" ]
}

@test "unreferenced build older than retention is removed" {
  make_dir old-unref $((NOW - 1000000))
  qf="${BATS_TMPDIR}/query-empty3.sh"
  cat >"${qf}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' __QOPS_E2B_GC_QUERY_OK__
EOF
  chmod +x "${qf}"
  run run_gc "${GC}" --query-cmd "${qf}"
  [ "$status" -eq 0 ]
  [ ! -d "${STORE}/old-unref" ]
  [[ "$output" == *"reclaimed_bytes"* ]]
}

@test "database error deletes nothing and exits non-zero" {
  make_dir old-unref $((NOW - 1000000))
  qf="${BATS_TMPDIR}/query-fail.sh"
  cat >"${qf}" <<'EOF'
#!/usr/bin/env bash
echo "connection refused" >&2
exit 1
EOF
  chmod +x "${qf}"
  run run_gc "${GC}" --query-cmd "${qf}"
  [ "$status" -ne 0 ]
  [ -d "${STORE}/old-unref" ]
}

@test "database-error test fails if the fail_closed guard is removed" {
  make_dir old-unref $((NOW - 1000000))
  mutated="${BATS_TMPDIR}/gc-no-fail.py"
  disable_guard fail_closed "${mutated}"
  qf="${BATS_TMPDIR}/query-fail2.sh"
  cat >"${qf}" <<'EOF'
#!/usr/bin/env bash
echo "connection refused" >&2
exit 1
EOF
  chmod +x "${qf}"
  run run_gc "${mutated}" --query-cmd "${qf}"
  [ "$status" -eq 0 ]
  [ ! -d "${STORE}/old-unref" ]
}

@test "missing sentinel is treated as a database error" {
  make_dir old-unref $((NOW - 1000000))
  qf="${BATS_TMPDIR}/query-nosentinel.sh"
  cat >"${qf}" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${qf}"
  run run_gc "${GC}" --query-cmd "${qf}"
  [ "$status" -ne 0 ]
  [ -d "${STORE}/old-unref" ]
  [[ "$output" == *"sentinel"* || "$stderr" == *"sentinel"* ]]
}

@test "dry-run removes nothing" {
  make_dir old-unref $((NOW - 1000000))
  qf="${BATS_TMPDIR}/query-empty4.sh"
  cat >"${qf}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' __QOPS_E2B_GC_QUERY_OK__
EOF
  chmod +x "${qf}"
  run run_gc "${GC}" --query-cmd "${qf}" --dry-run
  [ "$status" -eq 0 ]
  [ -d "${STORE}/old-unref" ]
}

@test "dry-run test fails if the dry_run guard is removed" {
  make_dir old-unref $((NOW - 1000000))
  mutated="${BATS_TMPDIR}/gc-no-dry.py"
  disable_guard dry_run "${mutated}"
  qf="${BATS_TMPDIR}/query-empty5.sh"
  cat >"${qf}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' __QOPS_E2B_GC_QUERY_OK__
EOF
  chmod +x "${qf}"
  run run_gc "${mutated}" --query-cmd "${qf}" --dry-run
  [ "$status" -eq 0 ]
  [ ! -d "${STORE}/old-unref" ]
}

@test "create-during-run race is kept" {
  make_dir raced $((NOW - 1000000))
  qf="${BATS_TMPDIR}/query-race.sh"
  state="${BATS_TMPDIR}/race.state"
  printf '0\n' >"${state}"
  cat >"${qf}" <<EOF
#!/usr/bin/env bash
n="\$(cat "${state}")"
n="\$((n + 1))"
printf '%s\n' "\$n" >"${state}"
if [[ "\$n" -eq 1 ]]; then
  printf '%s\n' __QOPS_E2B_GC_QUERY_OK__
  exit 0
fi
printf '%s\n' raced __QOPS_E2B_GC_QUERY_OK__
EOF
  chmod +x "${qf}"
  run run_gc "${GC}" --query-cmd "${qf}"
  [ "$status" -eq 0 ]
  [ -d "${STORE}/raced" ]
}

@test "race test fails if the race_requery guard is removed" {
  make_dir raced $((NOW - 1000000))
  mutated="${BATS_TMPDIR}/gc-no-race.py"
  disable_guard race_requery "${mutated}"
  qf="${BATS_TMPDIR}/query-race2.sh"
  state="${BATS_TMPDIR}/race2.state"
  printf '0\n' >"${state}"
  cat >"${qf}" <<EOF
#!/usr/bin/env bash
n="\$(cat "${state}")"
n="\$((n + 1))"
printf '%s\n' "\$n" >"${state}"
if [[ "\$n" -eq 1 ]]; then
  printf '%s\n' __QOPS_E2B_GC_QUERY_OK__
  exit 0
fi
printf '%s\n' raced __QOPS_E2B_GC_QUERY_OK__
EOF
  chmod +x "${qf}"
  run run_gc "${mutated}" --query-cmd "${qf}"
  [ "$status" -eq 0 ]
  [ ! -d "${STORE}/raced" ]
}
