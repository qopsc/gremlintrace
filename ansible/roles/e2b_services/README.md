# e2b_services

Installs the E2B dist, renders service env files, migrates, seeds, and runs
orchestrator / api / client-proxy under systemd.

## Layout

| Path | Purpose |
|---|---|
| `/usr/local/lib/e2b/<e2b_dist_version>` | Unpacked dist (SHA256SUMS verified before install) |
| `/usr/local/lib/e2b/current` | Symlink to the installed version |
| `/fc-envd/envd` | envd binary copied from the dist |
| `/etc/qops/e2b/orchestrator.env` | Orchestrator env (mode `0600`) |
| `/etc/qops/e2b/api.env` | API env (mode `0600`) |
| `/etc/qops/e2b/client-proxy.env` | client-proxy env (mode `0600`) |
| `/etc/qops/e2b/node-id` | Persisted `NODE_ID` (created once) |

Env files carry database passwords and `SANDBOX_ACCESS_TOKEN_HASH_SEED`. Tasks that
read or render them use `no_log`.

## Units

| Unit | User | Notes |
|---|---|---|
| `e2b-orchestrator.service` | root | `Requires=docker.service`; `RequiresMountsFor=/orchestrator /mnt/hugepages`; no sandboxing directives |
| `e2b-api.service` | `e2b` | `After=e2b-orchestrator`; `api --port 8080` |
| `e2b-client-proxy.service` | `e2b` | `After=e2b-orchestrator` |

`FORCE_STOP` is written to `orchestrator.env` from `e2b_services_orchestrator_force_stop`
(default `false`). `upgrade.yml` sets it `true` before `systemctl stop` so Firecracker
processes in `/sys/fs/cgroup/e2b/sbx-*` are not drained for up to 35 minutes.

## Seed and limits

`bin/e2b-seed` runs only when `SELECT 1 FROM teams WHERE email=$1` is empty. There is
no file marker. The printed `Team API Key` is written to `E2B_API_KEY` in
`/etc/qops/secrets.env`.

Then, idempotently:

- insert/update `addons` row `qops-concurrency` with
  `extra_concurrent_sandboxes = e2b_max_concurrent_sandboxes - 20` and
  `extra_concurrent_template_builds`
- `UPDATE tiers SET max_length_hours` for `base_v1` only when raised

ClickHouse TTL is applied after goose via
`/usr/local/lib/qops/e2b-apply-clickhouse-ttl.sh`.

## Health

Waits for `http://127.0.0.1:5008/health`, `http://127.0.0.1:8080/health` (retries
HTTP 503 until a node is discovered), and TCP `:3003`.

Implemented in **Task 7** (see `../../../docs/superpowers/specs/2026-08-28-kodus-e2b-selfhost-design.md`, Phase 2).
