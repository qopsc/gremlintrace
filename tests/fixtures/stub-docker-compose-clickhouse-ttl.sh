#!/usr/bin/env bash
# Stub docker compose for e2b-apply-clickhouse-ttl.sh tests.
set -euo pipefail

LOG="${CLICKHOUSE_TTL_STUB_LOG:?CLICKHOUSE_TTL_STUB_LOG is required}"

subcmd=""
declare -a REST=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f)
      shift 2
      ;;
    ps | exec)
      subcmd="$1"
      shift
      REST=("$@")
      break
      ;;
    *)
      shift
      ;;
  esac
done

case "${subcmd}" in
  ps)
    if [[ " ${REST[*]} " == *" --services "* ]]; then
      if [[ "${CLICKHOUSE_RUNNING:-1}" == "1" ]]; then
        printf 'clickhouse\n'
      fi
      exit 0
    fi
    printf 'unexpected ps args: %s\n' "${REST[*]}" >&2
    exit 1
    ;;
  exec)
    query=""
    i=0
    while (( i < ${#REST[@]} )); do
      case "${REST[i]}" in
        -T)
          i=$((i + 1))
          ;;
        clickhouse)
          i=$((i + 1))
          ;;
        clickhouse-client)
          i=$((i + 1))
          ;;
        --query)
          query="${REST[i + 1]}"
          break
          ;;
        *)
          i=$((i + 1))
          ;;
      esac
    done
    [[ -n "${query}" ]] || {
      printf 'missing --query in exec args: %s\n' "${REST[*]}" >&2
      exit 1
    }
    printf '%s\n' "${query}" >>"${LOG}"

    if [[ -n "${SQL_FAIL:-}" && "${query}" == ALTER* ]]; then
      printf '%s\n' "${SQL_FAIL}" >&2
      exit 1
    fi

    if [[ "${query}" == ALTER* ]]; then
      exit 0
    fi

    case "${query}" in
      *"name = 'metrics_gauge_local'"*)
        if [[ "${query}" == *"count()"* ]]; then
          printf '%s\n' "${TABLE_EXISTS:-1}"
        else
          printf '%s\n' "${TTL_GAUGE:-toDateTime(TimeUnix) + toIntervalDay(30)}"
        fi
        ;;
      *"name = 'metrics_sum_local'"*)
        if [[ "${query}" == *"count()"* ]]; then
          printf '%s\n' "${TABLE_EXISTS:-1}"
        else
          printf '%s\n' "${TTL_SUM:-toDateTime(TimeUnix) + toIntervalDay(30)}"
        fi
        ;;
      *)
        printf 'unexpected query: %s\n' "${query}" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    printf 'unexpected docker compose subcommand: %s\n' "${subcmd}" >&2
    exit 1
    ;;
esac
