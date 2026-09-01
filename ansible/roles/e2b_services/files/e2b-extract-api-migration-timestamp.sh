#!/usr/bin/env bash
# Extract the 14-digit expectedMigrationTimestamp embedded in bin/api via
# strings. Fail closed on zero or multiple unique matches.
#
# Sourced by ci/validate-e2b-dist.sh and e2b-assert-dist-pair.sh. Also
# executable: e2b-extract-api-migration-timestamp.sh BIN

extract_api_migration_timestamp() {
  local bin="$1"
  local -a matches=()
  local line
  if [[ ! -e "${bin}" ]]; then
    echo "API binary missing: ${bin}" >&2
    return 1
  fi
  while IFS= read -r line; do
    matches+=("${line}")
  done < <(strings -a "${bin}" | grep -E '^[0-9]{14}$' | LC_ALL=C sort -u)
  if (( ${#matches[@]} != 1 )); then
    if (( ${#matches[@]} == 0 )); then
      echo "could not extract expectedMigrationTimestamp from api binary (no 14-digit string)" >&2
      return 1
    fi
    echo "ambiguous expectedMigrationTimestamp in api binary: ${matches[*]}" >&2
    return 1
  fi
  printf '%s\n' "${matches[0]}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  extract_api_migration_timestamp "${1:?api binary required}"
fi
