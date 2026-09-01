#!/usr/bin/env python3
"""Run qops-e2b-gc with shutil.rmtree held until a hold file is removed.

Used by the GC lock-spans-rmtree bats test so a concurrent inserter can try
to take the same lock *during* delete. Production still runs in-process;
only rmtree is wrapped.
"""
from __future__ import annotations

import os
import runpy
import shutil
import sys
import time
from pathlib import Path

gc = sys.argv[1]
sys.argv = [gc, *sys.argv[2:]]

orig = shutil.rmtree
started = os.environ.get("QOPS_GC_RMTREE_STARTED", "")
hold = os.environ.get("QOPS_GC_RMTREE_HOLD", "")


def rmtree(path, *args, **kwargs):  # noqa: ANN401
    if started:
        Path(started).write_text("started\n", encoding="utf-8")
    if hold:
        deadline = time.time() + 30
        while Path(hold).exists() and time.time() < deadline:
            time.sleep(0.05)
    return orig(path, *args, **kwargs)


shutil.rmtree = rmtree
runpy.run_path(gc, run_name="__main__")
