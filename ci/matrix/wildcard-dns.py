#!/usr/bin/env python3
"""Tiny DNS responder for CI: resolve zone suffixes to a fixed A record.

Used by ci/matrix/prepare-host.sh so preflight's *random* `*.e2b.<domain>`
label resolves. /etc/hosts has no wildcard semantics and cannot satisfy that
check with a fixed `preflight-check` name.

Unknown names are forwarded to --upstream (default 8.8.8.8) so other lookups
still work when this process is the resolver for the zone.
"""
from __future__ import annotations

import argparse
import os
import socket
import struct
import sys
from pathlib import Path


def encode_name(name: str) -> bytes:
    out = bytearray()
    for label in name.rstrip(".").split("."):
        raw = label.encode("ascii")
        out.append(len(raw))
        out.extend(raw)
    out.append(0)
    return bytes(out)


def decode_name(msg: bytes, offset: int) -> tuple[str, int]:
    labels: list[str] = []
    jumped = False
    pos = offset
    end = offset
    hops = 0
    while hops < 16:
        hops += 1
        if pos >= len(msg):
            break
        length = msg[pos]
        if length == 0:
            if not jumped:
                end = pos + 1
            break
        if length & 0xC0 == 0xC0:
            if pos + 1 >= len(msg):
                break
            ptr = ((length & 0x3F) << 8) | msg[pos + 1]
            if not jumped:
                end = pos + 2
            pos = ptr
            jumped = True
            continue
        pos += 1
        labels.append(msg[pos : pos + length].decode("ascii", errors="replace"))
        pos += length
        if not jumped:
            end = pos
    return ".".join(labels).lower(), end


def build_response(query: bytes, address: str, zones: list[str]) -> bytes | None:
    if len(query) < 12:
        return None
    flags = struct.unpack("!H", query[2:4])[0]
    qdcount = struct.unpack("!H", query[4:6])[0]
    if qdcount < 1:
        return None
    qname, pos = decode_name(query, 12)
    if pos + 4 > len(query):
        return None
    qtype, qclass = struct.unpack("!HH", query[pos : pos + 4])
    question = query[12 : pos + 4]

    in_zone = any(
        qname == zone or qname.endswith("." + zone) for zone in zones
    )
    # Standard query, IN A.
    header_id = query[:2]
    if not in_zone or qtype not in (1, 255) or qclass != 1:
        return None

    ip = socket.inet_aton(address)
    answer = encode_name(qname) + struct.pack("!HHIH", 1, 1, 30, 4) + ip
    flags_out = (flags & 0x0100) | 0x8000  # QR, copy RD
    header = header_id + struct.pack("!HHHHH", flags_out, 1, 1, 0, 0)
    return header + question + answer


def forward(query: bytes, upstream: str, timeout: float) -> bytes | None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        sock.sendto(query, (upstream, 53))
        data, _ = sock.recvfrom(4096)
        return data
    except OSError:
        return None
    finally:
        sock.close()


def main() -> int:
    parser = argparse.ArgumentParser(prog="wildcard-dns.py")
    parser.add_argument("--bind", default="127.0.0.54")
    parser.add_argument("--port", type=int, default=53)
    parser.add_argument("--address", required=True, help="A record target")
    parser.add_argument(
        "--zone",
        action="append",
        dest="zones",
        required=True,
        help="zone suffix to answer (repeatable), e.g. e2b.ci.qops.test",
    )
    parser.add_argument("--upstream", default="8.8.8.8")
    parser.add_argument("--pidfile", default="")
    args = parser.parse_args()
    zones = [z.rstrip(".").lower() for z in args.zones]

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((args.bind, args.port))
    if args.pidfile:
        Path(args.pidfile).write_text(str(os.getpid()) + "\n", encoding="utf-8")
    sys.stderr.write(
        f"wildcard-dns: bind={args.bind}:{args.port} address={args.address} "
        f"zones={','.join(zones)}\n"
    )
    sys.stderr.flush()
    while True:
        data, addr = sock.recvfrom(4096)
        response = build_response(data, args.address, zones)
        if response is None:
            response = forward(data, args.upstream)
        if response:
            sock.sendto(response, addr)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(0)
