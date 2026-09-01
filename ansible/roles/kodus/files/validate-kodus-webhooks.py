#!/usr/bin/env python3
"""Validate Kodus webhook URLs against the dedicated webhooks host (not WEB_HOSTNAME_API)."""
from __future__ import annotations

import argparse
import re
import sys
from urllib.parse import urlparse

WEBHOOKS = (
    ("API_GITHUB_CODE_MANAGEMENT_WEBHOOK", ("/github/webhook",)),
    ("API_GITLAB_CODE_MANAGEMENT_WEBHOOK", ("/gitlab/webhook",)),
    ("GLOBAL_BITBUCKET_CODE_MANAGEMENT_WEBHOOK", ("/bitbucket/webhook",)),
    ("GLOBAL_AZURE_REPOS_CODE_MANAGEMENT_WEBHOOK", ("/azdevops/webhook", "/azure-repos/webhook")),
    ("API_FORGEJO_CODE_MANAGEMENT_WEBHOOK", ("/forgejo/webhook",)),
)


def parse_env(path: str) -> dict[str, str]:
    values: dict[str, str] = {}
    assign = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
    for raw in open(path, encoding="utf-8"):
        match = assign.match(raw.strip())
        if not match:
            continue
        value = match.group(2)
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
            value = value[1:-1]
        values[match.group(1)] = value
    return values


def validate(env: dict[str, str], expected_host: str) -> list[str]:
    errors: list[str] = []
    present = 0
    for var, paths in WEBHOOKS:
        url = env.get(var) or ""
        if not url:
            continue
        present += 1
        parsed = urlparse(url)
        if parsed.scheme != "https":
            errors.append(f"{var} must use https://")
            continue
        if parsed.hostname != expected_host:
            errors.append(f"{var} host must be {expected_host}, got {parsed.hostname}")
        if parsed.path not in paths:
            errors.append(f"{var} path must be one of {'|'.join(paths)}, got {parsed.path}")
    if present == 0:
        errors.append("at least one Git webhook URL must be set")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--env", required=True)
    parser.add_argument("--webhooks-host", required=True)
    args = parser.parse_args()
    errors = validate(parse_env(args.env), args.webhooks_host)
    if errors:
        print("webhook validation failed:")
        for item in errors:
            print(item)
        return 1
    print("webhook validation ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
