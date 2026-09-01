#!/usr/bin/env python3
"""Stub of e2b/patches/0001-force-stop-marker.patch shutdown decision.

Does not compile E2B. Mirrors: ForceStop stays true if the env was set at
start; otherwise a present /orchestrator/force-stop marker overrides to true.
"""
from __future__ import annotations

from pathlib import Path


def effective_force_stop(env_force_stop: bool, marker: Path) -> bool:
    if env_force_stop:
        return True
    try:
        return marker.exists()
    except OSError:
        return False


def patch_mentions_marker(patch: Path) -> bool:
    text = patch.read_text(encoding="utf-8")
    return (
        "/orchestrator/force-stop" in text
        and "config.ForceStop = true" in text
        and "os.Stat" in text
    )
