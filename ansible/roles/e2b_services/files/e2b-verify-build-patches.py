#!/usr/bin/env python3
"""Verify that BUILD_INFO records the patch set required by this deployment."""
from __future__ import annotations

import json
import pathlib
import sys


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "usage: e2b-verify-build-patches.py BUILD_INFO PATCH_FILENAME SHA256",
            file=sys.stderr,
        )
        return 2

    build_info_path = pathlib.Path(sys.argv[1])
    expected_name = sys.argv[2]
    expected_sha256 = sys.argv[3].lower()
    try:
        data = json.loads(build_info_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"cannot read BUILD_INFO: {exc}", file=sys.stderr)
        return 1

    patches = data.get("patches")
    if not isinstance(patches, list):
        print("BUILD_INFO patches is missing or not a list", file=sys.stderr)
        return 1

    matches = [
        patch
        for patch in patches
        if isinstance(patch, dict) and patch.get("filename") == expected_name
    ]
    if len(matches) != 1:
        print(
            f"BUILD_INFO must contain exactly one patch named {expected_name!r}",
            file=sys.stderr,
        )
        return 1

    observed_sha256 = str(matches[0].get("sha256", "")).lower()
    if observed_sha256 != expected_sha256:
        print(
            f"BUILD_INFO patch {expected_name} sha256 {observed_sha256!r} "
            f"!= expected {expected_sha256!r}",
            file=sys.stderr,
        )
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
