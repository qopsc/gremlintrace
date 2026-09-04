#!/usr/bin/env python3
"""Return true when two CIDR blocks overlap."""
from __future__ import annotations

import ipaddress
import sys


def main() -> int:
    left = ipaddress.ip_network(sys.argv[1], strict=False)
    right = ipaddress.ip_network(sys.argv[2], strict=False)
    print("true" if left.overlaps(right) else "false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
