#!/usr/bin/env python3
"""Emit versions.yml entries for GITHUB_OUTPUT (key=value per line)."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from yaml_versions import github_output


def main() -> int:
    versions_path = Path(sys.argv[1] if len(sys.argv) > 1 else "versions.yml")
    github_output(versions_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
