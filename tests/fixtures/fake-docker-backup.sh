#!/usr/bin/env bash
# Fake `docker` for qops-backup tests. Understands only
#   docker compose <options...> exec -T <service> <command...>
# and runs <command...> on this host with tests/fixtures/fake-bin first on PATH,
# so the container-side snippets (mongodump, rabbitmqctl, pg_dump) are exercised
# against strict fakes instead of being skipped.
set -euo pipefail

FIXTURES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="${FAKE_DOCKER_LOG:-/dev/null}"

[[ "${1:-}" == "compose" ]] || { echo "fake docker: unsupported: $*" >&2; exit 64; }
shift
while [[ $# -gt 0 && "$1" != "exec" ]]; do shift; done
[[ "${1:-}" == "exec" ]] || { echo "fake docker: no exec in: $*" >&2; exit 64; }
shift
[[ "${1:-}" == "-T" ]] && shift
service="$1"
shift
printf 'exec %s %s\n' "${service}" "$*" >>"${LOG}"

export PATH="${FIXTURES}/fake-bin:${PATH}"
exec "$@"
