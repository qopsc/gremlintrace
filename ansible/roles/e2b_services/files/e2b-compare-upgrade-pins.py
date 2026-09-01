#!/usr/bin/env python3
"""Decide whether an E2B upgrade must rebuild sandbox templates.

Template rebuilds are required when envd, kernel, or Firecracker pins change
(feature gating keys on env_builds.envd_version). Other BUILD_INFO keys
(e2b_pin, goose_version, expected_migration_timestamp, …) do not, by
themselves, trigger a rebuild.

Compared keys:
  envd_version          from installed vs new BUILD_INFO
  firecracker_version   from installed orchestrator.env vs versions.yml
  kernel_version        from installed orchestrator.env vs versions.yml
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys

REBUILD_BUILD_INFO_KEYS = ("envd_version",)
REBUILD_ENV_KEYS = (
    ("firecracker_version", "DEFAULT_FIRECRACKER_VERSION"),
    ("kernel_version", "DEFAULT_KERNEL_VERSION"),
)


def load_build_info(path: pathlib.Path) -> dict:
    if not path.is_file():
        raise SystemExit(f"BUILD_INFO missing: {path}")
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise SystemExit(f"BUILD_INFO is not a JSON object: {path}")
    return data


def parse_env_file(path: pathlib.Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        raise SystemExit(f"orchestrator env missing: {path}")
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value
    return values


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--installed-build-info", required=True)
    parser.add_argument("--new-build-info", required=True)
    parser.add_argument("--installed-env", required=True)
    parser.add_argument("--new-firecracker", required=True)
    parser.add_argument("--new-kernel", required=True)
    args = parser.parse_args()

    installed = load_build_info(pathlib.Path(args.installed_build_info))
    new = load_build_info(pathlib.Path(args.new_build_info))
    env = parse_env_file(pathlib.Path(args.installed_env))

    compared: dict[str, list[str]] = {}
    changed: list[str] = []

    for key in REBUILD_BUILD_INFO_KEYS:
        old = str(installed.get(key, ""))
        new_val = str(new.get(key, ""))
        compared[key] = [old, new_val]
        if old != new_val:
            changed.append(key)

    env_map = {
        "firecracker_version": args.new_firecracker,
        "kernel_version": args.new_kernel,
    }
    for public_key, env_key in REBUILD_ENV_KEYS:
        old = env.get(env_key, "")
        new_val = env_map[public_key]
        compared[public_key] = [old, new_val]
        if old != new_val:
            changed.append(public_key)

    result = {
        "rebuild_templates": bool(changed),
        "changed": changed,
        "compared": compared,
        "rebuild_keys": ["envd_version", "firecracker_version", "kernel_version"],
    }
    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
