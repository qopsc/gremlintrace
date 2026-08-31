# e2b_datastores

Docker Compose project **`e2b-data`** for E2B backing services. Every published port binds **`127.0.0.1`** on the host.

## Compose layout

| Item | Value |
|---|---|
| Project name | `e2b-data` (`e2b_datastores_compose_project`) |
| Compose file | `/etc/qops/e2b-data/docker-compose.yml` |
| OTel config | `/etc/qops/e2b-data/otel-collector.yaml` (mode `0600`) |

## Services and ports (host localhost only)

| Service | Container name | Host bind |
|---|---|---|
| `postgres` | `e2b-data-postgres` | `127.0.0.1:5433` → 5432 |
| `redis` | `e2b-data-redis` | `127.0.0.1:6379` |
| `clickhouse` | `e2b-data-clickhouse` | `127.0.0.1:8123`, `127.0.0.1:9000` |
| `otel-collector` | `e2b-data-otel-collector` | `127.0.0.1:4317` (OTLP gRPC), `127.0.0.1:13133` (health) |

OTel listens on `0.0.0.0` **inside** the container namespace; Docker publishes those ports on `127.0.0.1` only.

Postgres 18 stores data under `/var/lib/postgresql/18/docker`; the named volume mounts at `/var/lib/postgresql` (not the pre-18 `/var/lib/postgresql/data` path).

Image references use `versions.yml` keys `e2b_*_image` / `e2b_*_tag` only.

## Postgres bootstrap

On first volume init and on every re-run (catalog-gated):

- `CREATE SCHEMA IF NOT EXISTS extensions`
- `CREATE EXTENSION IF NOT EXISTS pgcrypto SCHEMA extensions`

Phase 0 note: upstream CI creates `pgcrypto` before goose; the spec only requires the `extensions` schema — both are created here.

## Secrets

Compose services load `/etc/qops/secrets.env` via `env_file`. The otel collector reads ClickHouse credentials from `${env:E2B_CLICKHOUSE_*}`; no plaintext password is written into the rendered config.

## ClickHouse TTL (task 7 hook)

ClickHouse TTL **cannot** be applied in this role: `metrics_gauge_local` / `metrics_sum_local` are created by goose migrations in `e2b_services`.

`e2b_services` must invoke after migrations:

```bash
/usr/local/lib/qops/e2b-apply-clickhouse-ttl.sh \
  /etc/qops/e2b-data/docker-compose.yml \
  <e2b_clickhouse_retention_days>
```

The helper alters TTL on `TimeUnix` and skips when already configured.

Implemented in **Task 6** (see `../../../docs/superpowers/specs/2026-08-28-kodus-e2b-selfhost-design.md`, Phase 2).
