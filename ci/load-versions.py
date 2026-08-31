#!/usr/bin/env python3
"""Emit versions.yml entries for GITHUB_OUTPUT (key=value per line)."""
from __future__ import annotations

import os
import sys
from pathlib import Path

import yaml


def main() -> int:
    versions_path = Path(sys.argv[1] if len(sys.argv) > 1 else "versions.yml")
    with versions_path.open(encoding="utf-8") as fh:
        data = yaml.safe_load(fh)
    if not isinstance(data, dict):
        print(f"error: {versions_path} is not a mapping", file=sys.stderr)
        return 1

    out_path = os.environ.get("GITHUB_OUTPUT")
    lines: list[str] = []
    for key, value in data.items():
        if value is None or str(value).strip() == "":
            print(f"error: empty value for {key!r}", file=sys.stderr)
            return 1
        text = str(value)
        if any(ch in text for ch in "\n\r"):
            print(f"error: multiline value for {key!r} is not supported", file=sys.stderr)
            return 1
        lines.append(f"{key}={text}")

    payload = "\n".join(lines) + "\n"
    if out_path:
        with open(out_path, "a", encoding="utf-8") as fh:
            fh.write(payload)
    else:
        sys.stdout.write(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
