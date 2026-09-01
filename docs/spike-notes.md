# Phase 0 spike notes (gate checklist)

**Phase 0 has not been executed.** There is no KVM-capable lab host in this development environment. Every exit criterion below is **unchecked**. Do not treat M1 installer code or CI as a substitute for this gate on nested-virt or bare-metal hardware.

Unchecked Phase 0 gates (must remain until the lab run):

- [ ] E2B API log shows sandbox from Kodus worker on our API (`usedTemplate=false` never)
- [ ] Review comment on canary PR with cross-file/AST context
- [ ] ≥ 700 s streamed `commands.run` through public hostname
- [ ] Isolation probe from sandbox (`:5008` blocked, npm allowed, LAN blocked)
- [ ] Pause / autoResume / kill disk layout under Local FS
- [ ] 10 parallel reviews vs `max-starting-instances-per-node=3`
- [ ] `systemctl restart e2b-orchestrator` under load (no ns/veth/nbd/cgroup leaks)
- [ ] Nested-virt timings
- [ ] `ENVIRONMENT=prod` + `SERVICE_DISCOVERY_PROVIDER=local`


Record results on the Proxmox VM (Ubuntu 24.04, CPU `host`, nested virt, ≥ 8 vCPU, 32 GiB RAM, 200 GiB disk) when Phase 0 runs.

## How to use this document

For each item: mark **PASS / FAIL / SKIP**, date, operator, and measured values. Leave assumptions explicit until disproven.

---

## Exit criteria (spec §Phase 0 step 10)

| # | Criterion | Result | Notes / measurements |
|---|---|---|---|
| 1 | E2B API log shows sandbox from Kodus worker on **our** API; worker never logs `falling back to default` (`usedTemplate=false`) | ☐ unchecked | |
| 2 | Review comment on canary PR **with cross-file/AST context** (graph stage; `bun install -g @kodus/kodus-graph@0.3.0` in sandbox) | ☐ unchecked | |
| 3 | ≥ 700 s streamed `commands.run` through public hostname; WebSocket `/ws` survives Traefik → client-proxy | ☐ unchecked | |
| 4 | Isolation probe from sandbox: `:5008/health` on host public IP **fails**; npm **succeeds**; LAN IP **fails** | ☐ unchecked | |
| 5 | Pause on 35-min timeout + `autoResume`; `Sandbox.kill` on paused sandbox — record disk under `LOCAL_TEMPLATE_STORAGE_BASE_PATH` | ☐ unchecked | Feeds GC design |
| 6 | 10 parallel reviews: observe `max-starting-instances-per-node=3` and tier concurrency; note queueing | ☐ unchecked | |
| 7 | `systemctl restart e2b-orchestrator` under load: no `ns-*` / `veth-*` / nbd / cgroup leaks | ☐ unchecked | CI runs a lighter variant on GH runners |
| 8 | Nested-virt timings: cold start, template build, ~100k-LOC review latency; `kvm.nx_huge_pages=never` needed? | ☐ unchecked | |
| 9 | `ENVIRONMENT=prod` + explicit `SERVICE_DISCOVERY_PROVIDER=local` works (vs `local` env flag behaviour) | ☐ unchecked | See assumptions |

---

## Unverified assumptions

### `ENVIRONMENT=prod` vs `local`

- **Assumption:** Installer uses `ENVIRONMENT=local` per upstream CI single-node recipe (`e2b_services_environment`).
- **Risk:** `local` flips ~9 feature flags to dev defaults and disables orchestrator single-instance lock; `prod` + `SERVICE_DISCOVERY_PROVIDER=local` may be required for production parity.
- **Phase 0 test:** Repeat step 6 with `ENVIRONMENT=prod`, `SERVICE_DISCOVERY_PROVIDER=local`, compare behaviour.
- **Result:** ☐ unchecked

### `SHARED_CHUNK_CACHE_PATH` and persistent-volume variables

- **Assumption:** Omitted intentionally (design §Key configuration reference); upstream CI sets `SHARED_CHUNK_CACHE_PATH` unset.
- **Upstream:** CI action env may set chunk cache / PV paths not in our design.
- **Phase 0 test:** Run with and without `SHARED_CHUNK_CACHE_PATH` and E2B PV env vars; measure template build and sandbox resume.
- **Result:** ☐ unchecked

### `pgcrypto` extension

- **Assumption:** Only `extensions` schema required for migrations; `pgcrypto` not required (spec §E2B bootstrap).
- **Installer:** `e2b_datastores` creates `CREATE EXTENSION pgcrypto SCHEMA extensions` anyway (matches upstream CI).
- **Phase 0 test:** Bootstrap DB with schema only, run goose — confirm pass/fail.
- **Result:** ☐ unchecked

### `max-starting-instances-per-node=3`

- **Assumption:** Burst of 10 parallel reviews will queue at 3 concurrent starts (compile-time LaunchDarkly fallback).
- **Mitigation:** First `e2b/patches/` candidate makes limit env-overridable if Phase 0 shows unacceptable queueing.
- **Result:** ☐ unchecked

### Paused-sandbox snapshot disk layout

- **Assumption:** Kill after pause leaves dirs under `LOCAL_TEMPLATE_STORAGE_BASE_PATH/<buildID>/` with memfile/rootfs diffs; nothing upstream deletes on Local FS.
- **Feeds:** `qops-e2b-gc` retention (`e2b_snapshot_retention_hours`).
- **Live IDs:** storage keys are `env_build_assignments.build_id` for live templates (`envs.deleted_at IS NULL`) and live snapshots (`snapshots.env_id`). `snapshots.id` is a row UUID, not a storage key.
- **Header-chain walking:** on-disk headers can name parent `build_id`s. Parsing those headers reliably is **not implemented**. GC keeps the conservative assigned-`build_id` set only. Deleting an ancestor that a live snapshot header still points at is an **unverified M1 gap** — fail closed by not claiming chain-walking; do not delete based on `snapshots.id`. Live GC against Postgres is **unverified**.
- **Result:** ☐ unchecked

### Hairpin NAT

- **Assumption:** Worker reaches `api.e2b.<d>` via Traefik on same host (`kodus_extra_hosts_hairpin` fallback documented).
- **Phase 0 test:** Hairpin check from Kodus network container; broken-hairpin fallback with `E2B_API_URL` / `E2B_SANDBOX_URL`.
- **Result:** ☐ unchecked

### Nested-virt performance

- **Assumption:** Medium load (50–500 PRs/day) may need bare metal; nested virt acceptable for lab only until measured.
- **Result:** ☐ unchecked

---

## Upstream conflicts worked around

### 1. `doctor.sh` webhook host vs `WEB_HOSTNAME_API`

- **Upstream:** `kodustech/kodus-installer` `scripts/doctor.sh` requires webhook host to equal `WEB_HOSTNAME_API`.
- **Our design:** Dedicated `kodus-webhooks.<domain>` host (spec Phase 2 step 9).
- **Workaround:** `kodus` role validates webhook URLs against `kodus-webhooks.<d>`; `interpret-kodus-doctor.py` tolerates doctor failure **only** when errors are exactly the known `host must match WEB_HOSTNAME_API` set.
- **Verified:** bats fixture tests only — not on live install.

### 2. `install.sh` always passes `--force-recreate`

- **Upstream:** `scripts/install.sh` invokes compose with `--force-recreate`.
- **Our design:** Idempotent installs gated on digest + running containers (`kodus-install-if-needed.sh`).
- **Workaround:** Skip `install.sh` when digest matches and containers exist; run only when needed.
- **Verified:** bats tests only.

---

## CI vs Phase 0

| Check | Phase 0 | installer-matrix (ubuntu-24.04) |
|---|---|---|
| Full install + doctor | Required | Yes (when secrets configured) |
| Isolation probe | Required | Via `qops-doctor` |
| Canary PR review + graph stage | Required | **No** — synthetic webhook only |
| 700 s streamed `commands.run` | Required | **No** |
| Reboot → doctor | Required | **Skipped** (GH runner cannot reboot) |
| Orchestrator restart leaks | Required | Partial (restart + leak scan) |
| Upgrade from **previous** pin | Required | Same-pin upgrade only |
| 10 parallel reviews / throttling | Required | **No** |

---

## Sign-off

| Role | Name | Date | Phase 0 complete? |
|---|---|---|---|
| Operator | | | ☐ |
| Engineering | | | ☐ |

**Do not mark M1 production-ready until this table is complete.**
