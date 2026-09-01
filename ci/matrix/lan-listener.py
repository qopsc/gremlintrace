#!/usr/bin/env python3
"""Trivial HTTP listener for CI isolation-probe host-proof LAN target.

Binds --bind:--port and answers 200 OK. prepare-host.sh assigns 10.255.0.1
on lo and starts this on :80; run-bootstrap.sh stops it before Traefik binds
0.0.0.0:80.
"""
from __future__ import annotations

import argparse
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


class OkHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        body = b"ok\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args: object) -> None:
        return


def main() -> int:
    parser = argparse.ArgumentParser(prog="lan-listener.py")
    parser.add_argument("--bind", default="10.255.0.1")
    parser.add_argument("--port", type=int, default=80)
    parser.add_argument("--pidfile", default="")
    args = parser.parse_args()
    httpd = HTTPServer((args.bind, args.port), OkHandler)
    if args.pidfile:
        Path(args.pidfile).write_text(str(os.getpid()) + "\n", encoding="utf-8")
    httpd.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
