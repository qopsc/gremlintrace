#!/usr/bin/env python3
"""Read and update top-level scalar keys in versions.yml (stdlib only)."""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

TOP_LEVEL_KEY_RE = re.compile(
    r"^(?P<key>[a-zA-Z0-9_]+):\s*(?P<rest>.+?)\s*(?:#.*)?$"
)


def parse_scalar(raw: str) -> str:
    value = raw.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def load(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line.strip() == "---":
            continue
        if line[0] in (" ", "\t"):
            continue
        match = TOP_LEVEL_KEY_RE.match(line)
        if not match:
            raise SystemExit(f"{path}:{lineno}: invalid top-level entry")
        key = match.group("key")
        rest = match.group("rest").strip()
        if key in data:
            raise SystemExit(f"{path}:{lineno}: duplicate key {key!r}")
        if rest.startswith("{") or rest.startswith("["):
            raise SystemExit(
                f"{path}:{lineno}: flow mapping/sequence not allowed for scalar key {key!r}"
            )
        value = parse_scalar(rest)
        if not value:
            raise SystemExit(f"{path}:{lineno}: empty value for key {key!r}")
        data[key] = value
    return data


def get(path: Path, key: str) -> str:
    data = load(path)
    if key not in data:
        raise SystemExit(f"missing key {key!r} in {path}")
    return data[key]


def update(path: Path, updates: dict[str, str]) -> None:
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    seen: set[str] = set()
    out: list[str] = []
    for line in lines:
        stripped = line.lstrip()
        if stripped and not stripped.startswith("#") and not line.startswith((" ", "\t")):
            match = TOP_LEVEL_KEY_RE.match(line.rstrip("\n"))
            if match and match.group("key") in updates:
                key = match.group("key")
                indent = line[: len(line) - len(line.lstrip())]
                out.append(f'{indent}{key}: "{updates[key]}"\n')
                seen.add(key)
                continue
        out.append(line)
    missing = set(updates) - seen
    if missing:
        raise SystemExit(f"keys not found in {path}: {', '.join(sorted(missing))}")
    path.write_text("".join(out), encoding="utf-8")


def github_output(path: Path) -> None:
    data = load(path)
    out_path = os.environ.get("GITHUB_OUTPUT")
    lines = [f"{k}={v}\n" for k, v in data.items()]
    payload = "".join(lines)
    if out_path:
        with open(out_path, "a", encoding="utf-8") as fh:
            fh.write(payload)
    else:
        sys.stdout.write(payload)


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)

    get_parser = sub.add_parser("get")
    get_parser.add_argument("key")
    get_parser.add_argument("path", nargs="?", default="versions.yml")

    update_parser = sub.add_parser("update")
    update_parser.add_argument("path")
    update_parser.add_argument("pairs", nargs="+")

    gh_parser = sub.add_parser("github-output")
    gh_parser.add_argument("path", nargs="?", default="versions.yml")

    args = parser.parse_args()
    if args.cmd == "get":
        print(get(Path(args.path), args.key))
    elif args.cmd == "update":
        updates: dict[str, str] = {}
        for pair in args.pairs:
            key, value = pair.split("=", 1)
            updates[key] = value
        update(Path(args.path), updates)
    elif args.cmd == "github-output":
        github_output(Path(args.path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
