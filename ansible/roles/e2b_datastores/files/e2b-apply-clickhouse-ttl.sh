#!/usr/bin/env bash
# Apply ClickHouse metrics TTL when goose-created tables exist.
set -euo pipefail

COMPOSE_FILE="${1:?compose file}"
TTL_SQL="${2:?ttl sql file}"

if ! docker compose -f "${COMPOSE_FILE}" ps --status running --services | grep -qx clickhouse; then
  exit 0
fi

if ! docker compose -f "${COMPOSE_FILE}" exec -T clickhouse clickhouse-client --query \
  "EXISTS TABLE metrics_gauge"; then
  exit 0
fi

docker compose -f "${COMPOSE_FILE}" exec -T clickhouse clickhouse-client --multiquery <"${TTL_SQL}"
