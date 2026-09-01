#!/usr/bin/env python3
"""SQLite stand-in for e2b-gc-query.sh's psql helper.

Executes the query script's SQL against a fixture DB that looks like the
pinned E2B schema (envs, snapshots, env_builds, env_build_assignments).
"""
from __future__ import annotations

import os
import sqlite3
import sys


def main() -> int:
    db = os.environ.get("QOPS_GC_FIXTURE_DB", "")
    if not db:
        print("QOPS_GC_FIXTURE_DB missing", file=sys.stderr)
        return 1
    sql = ""
    args = sys.argv[1:]
    for i, arg in enumerate(args):
        if arg in ("-tAc", "-c") and i + 1 < len(args):
            sql = args[i + 1]
            break
    if not sql:
        print("no SQL", file=sys.stderr)
        return 1
    sql = sql.replace("::text", "")
    conn = sqlite3.connect(db)
    try:
        rows = conn.execute(sql).fetchall()
    except sqlite3.Error as exc:
        print(f"fixture query failed: {exc}", file=sys.stderr)
        return 1
    for row in rows:
        if row and row[0] is not None:
            print(row[0])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
