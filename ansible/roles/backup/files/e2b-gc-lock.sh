#!/usr/bin/env bash
# Hold SHARE ROW EXCLUSIVE on all tables used by the live-build query
# until stdin EOF, then COMMIT. qops-e2b-gc runs query+delete while this
# session is open so INSERT (ROW EXCLUSIVE) waits.
#
# Prints __QOPS_E2B_GC_LOCK_OK__ once the lock is held. Fail closed otherwise.
set -euo pipefail

PSQL_BIN="${1:?psql helper required}"
shift

python3 - "${PSQL_BIN}" "$@" <<'PY'
import sys
import subprocess
import time

LOCK_SQL = (
    "BEGIN;\n"
    "LOCK TABLE env_builds, env_build_assignments, snapshots, snapshot_templates "
    "IN SHARE ROW EXCLUSIVE MODE;\n"
    "SELECT '__QOPS_E2B_GC_LOCK_OK__';\n"
)
SENTINEL = "__QOPS_E2B_GC_LOCK_OK__"
psql = sys.argv[1]
args = sys.argv[2:]

proc = subprocess.Popen(
    [psql, *args, "-v", "ON_ERROR_STOP=1", "-A", "-t"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
)
assert proc.stdin is not None
assert proc.stdout is not None
try:
    proc.stdin.write(LOCK_SQL)
    proc.stdin.flush()
except BrokenPipeError:
    err = proc.stderr.read() if proc.stderr else ""
    sys.stderr.write(err or "psql closed while taking GC lock\n")
    sys.exit(proc.wait() or 1)

deadline = time.time() + 60
got = False
buf = ""
while time.time() < deadline:
    if proc.poll() is not None:
        break
    line = proc.stdout.readline()
    if not line:
        if proc.poll() is not None:
            break
        time.sleep(0.05)
        continue
    buf += line
    if SENTINEL in line:
        got = True
        break

if not got:
    err = ""
    if proc.stderr:
        try:
            err = proc.stderr.read()
        except OSError:
            err = ""
    sys.stderr.write(
        "qops-e2b-gc lock failed; refusing to delete anything\n" + (err or buf)
    )
    proc.kill()
    sys.exit(proc.wait() or 1)

sys.stdout.write(SENTINEL + "\n")
sys.stdout.flush()
sys.stdin.read()
try:
    proc.stdin.write("COMMIT;\n")
    proc.stdin.close()
except BrokenPipeError:
    pass
rc = proc.wait(timeout=30)
if rc not in (0, None):
    err = proc.stderr.read() if proc.stderr else ""
    sys.stderr.write(err or f"psql lock session exited {rc}\n")
    sys.exit(rc or 1)
sys.exit(0)
PY
