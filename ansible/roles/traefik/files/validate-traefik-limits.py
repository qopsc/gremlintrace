#!/usr/bin/env python3
"""Enforce load-bearing Traefik timeout and body-size bounds.

idleConnTimeout must parse as a Go duration strictly less than the client-proxy
idle timeout (default 610s). The documented API body minimum is 16 MiB; a
smaller override is rejected even though the rendered config does not install
a buffering middleware (streaming requires no buffer).
"""
from __future__ import annotations

import re
import sys

GO_DURATION = re.compile(r"(?P<value>\d+(?:\.\d+)?)(?P<unit>ns|us|µs|ms|s|m|h)")
UNIT_SECONDS = {
    "ns": 1e-9,
    "us": 1e-6,
    "µs": 1e-6,
    "ms": 1e-3,
    "s": 1.0,
    "m": 60.0,
    "h": 3600.0,
}


def parse_go_duration(raw: str) -> float:
    text = raw.strip()
    if text in {"0", "0s"}:
        return 0.0
    matches = list(GO_DURATION.finditer(text))
    if not matches:
        raise ValueError(f"not a Go duration: {raw!r}")
    consumed = "".join(match.group(0) for match in matches)
    if consumed != text:
        raise ValueError(f"not a Go duration: {raw!r}")
    total = 0.0
    for match in matches:
        total += float(match.group("value")) * UNIT_SECONDS[match.group("unit")]
    return total


def main(argv: list[str]) -> int:
    if len(argv) != 5:
        sys.stderr.write(
            "usage: validate-traefik-limits.py "
            "<idleConnTimeout> <maxRequestBodyBytes> <maxIdleDuration> <minBodyBytes>\n"
        )
        return 2
    idle_raw, body_raw, max_idle_raw, min_body_raw = argv[1], argv[2], argv[3], argv[4]
    try:
        idle = parse_go_duration(idle_raw)
        max_idle = parse_go_duration(max_idle_raw)
        body = int(body_raw)
        min_body = int(min_body_raw)
    except ValueError as exc:
        sys.stderr.write(f"invalid Traefik limit: {exc}\n")
        return 1
    if idle >= max_idle:
        sys.stderr.write(
            f"idleConnTimeout {idle_raw} ({idle:g}s) must be < {max_idle_raw} "
            f"(client-proxy idle is 610s; exceeding it breaks streamed commands.run)\n"
        )
        return 1
    if body < min_body:
        sys.stderr.write(
            f"traefik_api_max_request_body_bytes={body} must be >= {min_body} (16 MiB)\n"
        )
        return 1
    print("ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
