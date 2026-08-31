#!/usr/bin/env bash
# Apply ClickHouse metrics TTL after goose migrations (invoked by e2b_services).
set -euo pipefail

COMPOSE_FILE="${1:?compose file}"
RETENTION_DAYS="${2:?retention days required}"

if ! docker compose -f "${COMPOSE_FILE}" ps --status running --services | grep -qx clickhouse; then
  echo "clickhouse is not running" >&2
  exit 1
fi

exists="$(docker compose -f "${COMPOSE_FILE}" exec -T clickhouse clickhouse-client --query \
  "SELECT count() FROM system.tables WHERE database = currentDatabase() AND name = 'metrics_gauge_local'")"
if [[ "${exists}" != "1" ]]; then
  echo "metrics_gauge_local does not exist yet; run goose clickhouse migrations first" >&2
  exit 1
fi

for table in metrics_gauge_local metrics_sum_local; do
  current_ttl="$(docker compose -f "${COMPOSE_FILE}" exec -T clickhouse clickhouse-client --query \
    "SELECT extract(create_table_query, 'TTL (.*)') FROM system.tables WHERE database = currentDatabase() AND name = '${table}'")"
  if [[ "${current_ttl}" == *"toIntervalDay(${RETENTION_DAYS})"* ]]; then
    echo "${table}: TTL already set"
    continue
  fi
  docker compose -f "${COMPOSE_FILE}" exec -T clickhouse clickhouse-client --query \
    "ALTER TABLE ${table} MODIFY TTL toDateTime(TimeUnix) + toIntervalDay(${RETENTION_DAYS})"
  echo "${table}: TTL updated"
done
