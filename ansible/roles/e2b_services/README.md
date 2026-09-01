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
| `/etc/qops/e2b/seeded-api-key` | Root-only durable copy of the team API key |

Env files carry database passwords and `SANDBOX_ACCESS_TOKEN_HASH_SEED`. Tasks that
read or render them use `no_log`.

## Bind addresses (host firewall, not an E2B patch)

The upstream Go binaries bind all interfaces by design:

| Process | Ports |
|---|---|
| orchestrator | 5007 (proxy), 5008 (health) |
| api | 8080 (HTTP), 5009 (gRPC) |
| client-proxy | 3002 (edge), 3003 (health) |

That is contained by the host nftables input chain (`policy drop`: loopback,
established, 22/80/443, and the veth redirect targets only). There is no
`e2b/patches/` bind-address change. Each systemd unit comments the same
policy next to the service definition.

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

`bin/e2b-seed` runs only when `SELECT 1 FROM teams WHERE email=$1` is **empty**.
The gate query accepts that empty result or exactly `1` (already seeded). Any
other result — including a connection error — **fails closed**. There is no
file marker. The seeder deletes that team's envs/snapshots on re-run, so a
malformed query must never fall through to seeding.

The printed `Team API Key` is written to a root-only durable file
(`/etc/qops/e2b/seeded-api-key`, mode `0600`) the moment it is parsed, then
copied into `E2B_API_KEY` in `/etc/qops/secrets.env` via an atomic temp+rename
write. Seeding is complete only after the key is verified present in
`secrets.env`. If the team row already exists, the durable file is used to
recover `secrets.env`; if the plaintext key is nowhere, the run fails (the
Postgres copy is hashed and unrecoverable).

Then, idempotently:

- insert/update `addons` row `qops-concurrency` with
  `extra_concurrent_sandboxes = e2b_max_concurrent_sandboxes - 20` and
  `extra_concurrent_template_builds`
- `UPDATE tiers SET max_length_hours` for `base_v1` only when raised

ClickHouse TTL is applied after goose via
`/usr/local/lib/qops/e2b-apply-clickhouse-ttl.sh`.

## Health

Waits for `http://127.0.0.1:5008/health`, `http://127.0.0.1:8080/health`
(retries connection failures and HTTP 503 until a node is discovered; any
other 4xx/5xx fails immediately with the status and body), and TCP `:3003`.

Implemented in **Task 7** (see `../../../docs/superpowers/specs/2026-08-28-kodus-e2b-selfhost-design.md`, Phase 2).
