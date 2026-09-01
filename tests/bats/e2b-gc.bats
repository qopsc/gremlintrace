#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  GC="${REPO_ROOT}/ansible/roles/backup/files/qops-e2b-gc"
  QUERY_SH="${REPO_ROOT}/ansible/roles/backup/files/e2b-gc-query.sh"
  FAKE_PSQL="${REPO_ROOT}/tests/fixtures/e2b-gc-fake-psql.py"
  STORE="${BATS_TMPDIR}/store"
  rm -rf "${STORE}"
  mkdir -p "${STORE}"
  NOW=1700000000
  LOCK_STUB="${BATS_TMPDIR}/lock.sh"
  SLOW_GC="${REPO_ROOT}/tests/fixtures/gc-run-slow-rmtree.py"
  cat >"${LOCK_STUB}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' __QOPS_E2B_GC_LOCK_OK__
cat >/dev/null
EOF
  chmod +x "${LOCK_STUB}"
}

teardown() {
  rm -f "${BATS_TMPDIR}/rmtree.hold"
  if [[ -n "${gc_pid:-}" ]] && kill -0 "${gc_pid}" 2>/dev/null; then
    kill "${gc_pid}" 2>/dev/null || true
    wait "${gc_pid}" 2>/dev/null || true
  fi
  if [[ -n "${ins_pid:-}" ]] && kill -0 "${ins_pid}" 2>/dev/null; then
    kill "${ins_pid}" 2>/dev/null || true
    wait "${ins_pid}" 2>/dev/null || true
  fi
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
    --lock-cmd "${LOCK_STUB}" \
    "$@"
}

run_gc_slow_rmtree() {
  local script="${1:-${GC}}"
  shift || true
  python3 "${SLOW_GC}" "${script}" \
    --store "${STORE}" \
    --retention-hours 24 \
    --now-epoch "${NOW}" \
    --docker-bin /bin/false \
    --summary-path "${BATS_TMPDIR}/missing-summary.json" \
    --lock-cmd "${LOCK_STUB}" \
    "$@"
}

wait_for_file() {
  local path="$1"
  local loops="${2:-200}"
  local i
  for ((i = 0; i < loops; i++)); do
    if [[ -f "${path}" ]]; then
      return 0
    fi
    sleep 0.05
  done
  echo "timed out waiting for ${path}" >&2
  return 1
}

release_lock_before_rmtree() {
  local dest="$1"
  python3 - "${GC}" "${dest}" <<'PY'
import sys

src, dest = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
needle = "            try:\n                shutil.rmtree(entry)\n"
# Keep the comment block if present; match the rmtree call site.
alt = (
    "            try:\n"
    "                # lock-cmd stdin is still open: INSERT cannot take the same\n"
    "                # lock until rmtree returns and the outer finally releases.\n"
    "                shutil.rmtree(entry)\n"
)
insert = (
    "            if lock_proc is not None:\n"
    "                release_lock(lock_proc)\n"
    "                lock_proc = None\n"
)
if text.count(alt) == 1:
    text = text.replace(alt, insert + alt, 1)
elif text.count(needle) == 1:
    text = text.replace(needle, insert + needle, 1)
else:
    raise SystemExit("rmtree call site not found or not unique")
open(dest, "w", encoding="utf-8").write(text)
PY
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

@test "missing lock-cmd deletes nothing and exits non-zero" {
  make_dir old-unref $((NOW - 1000000))
  qf="${BATS_TMPDIR}/query-empty-lock.sh"
  cat >"${qf}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' __QOPS_E2B_GC_QUERY_OK__
EOF
  chmod +x "${qf}"
  run python3 "${GC}" \
    --store "${STORE}" \
    --retention-hours 24 \
    --now-epoch "${NOW}" \
    --docker-bin /bin/false \
    --summary-path "${BATS_TMPDIR}/missing-summary.json" \
    --query-cmd "${qf}"
  [ "$status" -ne 0 ]
  [ -d "${STORE}/old-unref" ]
  [[ "$output" == *"lock-cmd"* || "$stderr" == *"lock-cmd"* ]]
}

@test "failed lock-cmd deletes nothing and exits non-zero" {
  make_dir old-unref $((NOW - 1000000))
  qf="${BATS_TMPDIR}/query-empty-lockfail.sh"
  cat >"${qf}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' __QOPS_E2B_GC_QUERY_OK__
EOF
  chmod +x "${qf}"
  fail_lock="${BATS_TMPDIR}/fail-lock.sh"
  cat >"${fail_lock}" <<'EOF'
#!/usr/bin/env bash
echo "could not lock" >&2
exit 1
EOF
  chmod +x "${fail_lock}"
  run run_gc "${GC}" --query-cmd "${qf}" --lock-cmd "${fail_lock}"
  [ "$status" -ne 0 ]
  [ -d "${STORE}/old-unref" ]
}

@test "insert after last query and before delete is kept" {
  make_dir raced $((NOW - 1000000))
  qf="${BATS_TMPDIR}/query-post.sh"
  inserted="${BATS_TMPDIR}/inserted-after-query"
  rm -f "${inserted}"
  cat >"${qf}" <<EOF
#!/usr/bin/env bash
if [[ -f "${inserted}" ]]; then
  printf '%s\n' raced __QOPS_E2B_GC_QUERY_OK__
  exit 0
fi
printf '%s\n' __QOPS_E2B_GC_QUERY_OK__
EOF
  chmod +x "${qf}"
  export QOPS_E2B_GC_INJECT_BEFORE_DELETE="touch '${inserted}'"
  run run_gc "${GC}" --query-cmd "${qf}"
  unset QOPS_E2B_GC_INJECT_BEFORE_DELETE
  [ "$status" -eq 0 ]
  [ -d "${STORE}/raced" ]
}

@test "post-query insert test fails if the final re-query guard is removed" {
  make_dir raced $((NOW - 1000000))
  mutated="${BATS_TMPDIR}/gc-no-final.py"
  disable_guard race_lock_final_query "${mutated}"
  qf="${BATS_TMPDIR}/query-post2.sh"
  inserted="${BATS_TMPDIR}/inserted-after-query-2"
  rm -f "${inserted}"
  cat >"${qf}" <<EOF
#!/usr/bin/env bash
if [[ -f "${inserted}" ]]; then
  printf '%s\n' raced __QOPS_E2B_GC_QUERY_OK__
  exit 0
fi
printf '%s\n' __QOPS_E2B_GC_QUERY_OK__
EOF
  chmod +x "${qf}"
  export QOPS_E2B_GC_INJECT_BEFORE_DELETE="touch '${inserted}'"
  run run_gc "${mutated}" --query-cmd "${qf}"
  unset QOPS_E2B_GC_INJECT_BEFORE_DELETE
  [ "$status" -eq 0 ]
  [ ! -d "${STORE}/raced" ]
}

# Property: a concurrent inserter blocked on the same lockfile cannot observe
# the target directory still present. By the time it acquires the lock, rmtree
# has finished (directory is gone). If GC releases the lock before rmtree, the
# inserter succeeds while the directory still exists and this test fails.
setup_lock_spans_rmtree() {
  make_dir raced $((NOW - 1000000))
  lockfile="${BATS_TMPDIR}/gc.lock"
  lock_held="${BATS_TMPDIR}/lock.held"
  rmtree_started="${BATS_TMPDIR}/rmtree.started"
  rmtree_hold="${BATS_TMPDIR}/rmtree.hold"
  insert_result="${BATS_TMPDIR}/insert.result"
  gc_out="${BATS_TMPDIR}/gc-lock.out"
  gc_err="${BATS_TMPDIR}/gc-lock.err"
  : >"${lockfile}"
  rm -f "${lock_held}" "${rmtree_started}" "${insert_result}"
  touch "${rmtree_hold}"
  export QOPS_GC_RMTREE_STARTED="${rmtree_started}"
  export QOPS_GC_RMTREE_HOLD="${rmtree_hold}"
  lockcmd="${BATS_TMPDIR}/flock-lock.sh"
  cat >"${lockcmd}" <<EOF
#!/usr/bin/env bash
exec 9>"${lockfile}"
flock -w 60 9 || exit 1
printf '%s\n' __QOPS_E2B_GC_LOCK_OK__
touch "${lock_held}"
cat >/dev/null
EOF
  chmod +x "${lockcmd}"
  inserter="${BATS_TMPDIR}/inserter.sh"
  cat >"${inserter}" <<EOF
#!/usr/bin/env bash
exec 8>"${lockfile}"
flock -w 60 8 || exit 1
if [[ -d "${STORE}/raced" ]]; then
  printf 'INSERTED_WHILE_DIR_EXISTS\n' >"${insert_result}"
else
  printf 'DIR_GONE\n' >"${insert_result}"
fi
EOF
  chmod +x "${inserter}"
  qf="${BATS_TMPDIR}/query-lockfile.sh"
  cat >"${qf}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' __QOPS_E2B_GC_QUERY_OK__
EOF
  chmod +x "${qf}"
}

@test "lock is held through rmtree so a blocked inserter cannot observe the directory" {
  setup_lock_spans_rmtree
  run_gc_slow_rmtree "${GC}" --query-cmd "${qf}" --lock-cmd "${lockcmd}" \
    >"${gc_out}" 2>"${gc_err}" &
  gc_pid=$!
  wait_for_file "${lock_held}"
  "${inserter}" &
  ins_pid=$!
  wait_for_file "${rmtree_started}"
  # If the lock was dropped before rmtree, the inserter writes during this window.
  sleep 0.2
  if [[ -f "${insert_result}" ]]; then
    echo "inserter acquired lock during rmtree: $(cat "${insert_result}")" >&2
    echo "gc stderr: $(cat "${gc_err}")" >&2
    rm -f "${rmtree_hold}"
    wait "${gc_pid}" || true
    wait "${ins_pid}" || true
    return 1
  fi
  kill -0 "${ins_pid}"
  rm -f "${rmtree_hold}"
  wait "${gc_pid}"
  gc_status=$?
  wait "${ins_pid}"
  [ "${gc_status}" -eq 0 ]
  [ ! -d "${STORE}/raced" ]
  [ -f "${insert_result}" ]
  [[ "$(cat "${insert_result}")" == "DIR_GONE" ]]
}

@test "lock-through-rmtree test fails if the lock is released before rmtree" {
  setup_lock_spans_rmtree
  mutated="${BATS_TMPDIR}/gc-unlock-before-rmtree.py"
  release_lock_before_rmtree "${mutated}"
  run_gc_slow_rmtree "${mutated}" --query-cmd "${qf}" --lock-cmd "${lockcmd}" \
    >"${gc_out}" 2>"${gc_err}" &
  gc_pid=$!
  wait_for_file "${lock_held}"
  "${inserter}" &
  ins_pid=$!
  wait_for_file "${rmtree_started}"
  wait_for_file "${insert_result}"
  got="$(cat "${insert_result}")"
  rm -f "${rmtree_hold}"
  wait "${gc_pid}" || true
  wait "${ins_pid}" || true
  [[ "${got}" == "INSERTED_WHILE_DIR_EXISTS" ]]
}

@test "assigned build_id protects a dir; snapshots.id does not" {
  make_dir snap-row-uuid $((NOW - 1000000))
  make_dir live-build-id $((NOW - 1000000))
  db="${BATS_TMPDIR}/gc-schema.sqlite"
  rm -f "${db}"
  python3 - "${db}" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.executescript("""
CREATE TABLE envs (id TEXT PRIMARY KEY, deleted_at TEXT);
CREATE TABLE snapshots (id TEXT PRIMARY KEY, env_id TEXT);
CREATE TABLE env_builds (id TEXT PRIMARY KEY);
CREATE TABLE env_build_assignments (env_id TEXT, build_id TEXT);
INSERT INTO envs (id, deleted_at) VALUES ('tmpl-live', NULL), ('snap-env', NULL), ('tmpl-dead', '2020-01-01');
INSERT INTO snapshots (id, env_id) VALUES ('snap-row-uuid', 'snap-env');
INSERT INTO env_builds (id) VALUES ('live-build-id'), ('dead-build-id');
INSERT INTO env_build_assignments (env_id, build_id) VALUES ('tmpl-live', 'live-build-id');
INSERT INTO env_build_assignments (env_id, build_id) VALUES ('snap-env', 'live-build-id');
INSERT INTO env_build_assignments (env_id, build_id) VALUES ('tmpl-dead', 'dead-build-id');
""")
conn.commit()
PY
  export QOPS_GC_FIXTURE_DB="${db}"
  grep -q 'env_build_assignments' "${QUERY_SH}"
  grep -q 'build_id' "${QUERY_SH}"
  ! grep -E 'SELECT[[:space:]]+id::text[[:space:]]+FROM[[:space:]]+snapshots' "${QUERY_SH}"
  run run_gc "${GC}" --query-cmd "${QUERY_SH} python3 ${FAKE_PSQL} x x x x x"
  [ "$status" -eq 0 ]
  [ -d "${STORE}/live-build-id" ]
  [ ! -d "${STORE}/snap-row-uuid" ]
}

@test "schema fixture: database error still deletes nothing" {
  make_dir live-build-id $((NOW - 1000000))
  make_dir snap-row-uuid $((NOW - 1000000))
  export QOPS_GC_FIXTURE_DB="${BATS_TMPDIR}/missing-db.sqlite"
  run run_gc "${GC}" --query-cmd "${QUERY_SH} python3 ${FAKE_PSQL} x x x x x"
  [ "$status" -ne 0 ]
  [ -d "${STORE}/live-build-id" ]
  [ -d "${STORE}/snap-row-uuid" ]
}

@test "query SQL does not treat snapshots.id as a storage key" {
  grep -v '^#' "${QUERY_SH}" | grep -v 'row UUID' | grep -q 'build_id'
  if grep -E 'SELECT[[:space:]]+id(::text)?[[:space:]]+FROM[[:space:]]+snapshots' "${QUERY_SH}"; then
    echo "snapshots.id must not be selected as a storage key" >&2
    return 1
  fi
}

