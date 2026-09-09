#!/usr/bin/env python3
"""Gate upstream scripts/doctor.sh: tolerate only the known webhook host-mismatch set."""
from __future__ import annotations

import argparse
import re
import sys

ANSI = re.compile(r"\x1b\[[0-9;]*m")

PROVIDERS = (
    ("API_GITHUB_CODE_MANAGEMENT_WEBHOOK", "GitHub"),
    ("API_GITLAB_CODE_MANAGEMENT_WEBHOOK", "GitLab"),
    ("GLOBAL_BITBUCKET_CODE_MANAGEMENT_WEBHOOK", "Bitbucket"),
    ("GLOBAL_AZURE_REPOS_CODE_MANAGEMENT_WEBHOOK", "Azure Repos"),
    ("API_FORGEJO_CODE_MANAGEMENT_WEBHOOK", "Forgejo"),
)


def mismatch_message(var: str, label: str, expected_host: str) -> str:
    return f"{var} ({label}) host must match WEB_HOSTNAME_API ({expected_host})."


def expected_mismatches(expected_host: str) -> set[str]:
    return {mismatch_message(var, label, expected_host) for var, label in PROVIDERS}


def strip_ansi(text: str) -> str:
    return ANSI.sub("", text)


def error_messages(output: str) -> list[str]:
    messages: list[str] = []
    for raw in strip_ansi(output).splitlines():
        line = raw.strip()
        if line.startswith("ERROR "):
            messages.append(line[len("ERROR ") :])
    return messages


def interpret(output: str, rc: int, expected_host: str) -> tuple[bool, str]:
    errors = error_messages(output)
    expected = expected_mismatches(expected_host)
    actual = set(errors)
    if rc == 0:
        if actual:
            return False, "doctor.sh exited 0 but printed ERROR lines: " + "; ".join(sorted(actual))
        return True, "doctor.sh passed"
    if actual == expected:
        return True, "doctor.sh failed only on known webhook host-mismatch diagnostics"
    extra = sorted(actual - expected)
    missing = sorted(expected - actual)
    parts = ["doctor.sh failed closed"]
    if extra:
        parts.append("unexpected: " + "; ".join(extra))
    if missing:
        parts.append("missing known mismatch: " + "; ".join(missing))
    if not extra and not missing and rc != 0:
        parts.append(f"exit {rc} with no ERROR lines")
    return False, ". ".join(parts)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-file", required=True)
    parser.add_argument("--rc", required=True, type=int)
    parser.add_argument("--expected-host", required=True)
    args = parser.parse_args()
    output = Path_read(args.output_file)
    ok, message = interpret(output, args.rc, args.expected_host)
    print(message)
    if not ok:
        print(output)
        return 1
    return 0


def Path_read(path: str) -> str:
    return open(path, encoding="utf-8").read()


if __name__ == "__main__":
    sys.exit(main())
