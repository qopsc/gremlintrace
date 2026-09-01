#!/usr/bin/env bash
# Run upgrade.yml on the installed cluster (same pin = no template rebuild path).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

./ci/matrix/run-bootstrap.sh --playbook upgrade
printf 'upgrade: ok\n'
