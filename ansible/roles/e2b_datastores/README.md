# e2b_datastores

Docker Compose project **`e2b-data`** for E2B backing services. Every published port binds **`127.0.0.1`** only.

## Compose layout

| Item | Value |
|---|---|
| Project name | `e2b-data` (`e2b_datastores_compose_project`) |
| Compose file | `/etc/qops/e2b-data/docker-compose.yml` |
| OTel config | `/etc/qops/e2b-data/otel-collector.yaml` |

## Services and ports (localhost only)

| Service | Container name | Host bind |
|---|---|---|
| `postgres` | `e2b-data-postgres` | `127.0.0.1:5433` → 5432 |
| `redis` | `e2b-data-redis` | `127.0.0.1:6379` |
| `clickhouse` | `e2b-data-clickhouse` | `127.0.0.1:8123`, `127.0.0.1:9000` |
| `otel-collector` | `e2b-data-otel-collector` | `127.0.0.1:4317` (OTLP gRPC), `127.0.0.1:13133` (health) |

Image references use `versions.yml` keys `e2b_*_image` / `e2b_*_tag` only.

## Postgres bootstrap

On first volume init and on every re-run via `psql`:

- `CREATE SCHEMA IF NOT EXISTS extensions`
- `CREATE EXTENSION IF NOT EXISTS pgcrypto SCHEMA extensions`

Phase 0 note: upstream CI creates `pgcrypto` before goose; the spec only requires the `extensions` schema — both are created here.

## Secrets

Reads `/etc/qops/secrets.env` (from `common` role): `E2B_POSTGRES_PASSWORD`, `E2B_CLICKHOUSE_USERNAME`, `E2B_CLICKHOUSE_PASSWORD`.

## ClickHouse TTL

`/etc/qops/e2b-data/clickhouse-init/01-ttl.sql` sets `MODIFY TTL` on `metrics_gauge` and `metrics_sum` using `e2b_clickhouse_retention_days`. Applied when tables exist (after task 7 migrations on first install).

Implemented in **Task 6** (see `../../../docs/superpowers/specs/2026-08-28-kodus-e2b-selfhost-design.md`, Phase 2).
