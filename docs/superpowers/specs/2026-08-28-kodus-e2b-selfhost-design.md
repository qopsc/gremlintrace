# Kodus + E2B self-hosted on plain Linux — deployment plan

## Context

QuantumOps wants a **repeatable installer** (and an internal reference deployment) that stands up
[Kodus](https://kodus.io) (AI code review, `kodustech/kodus-ai`, AGPL-3.0 community edition, installed via the MIT
`kodustech/kodus-installer` compose) together with a **self-hosted [E2B](https://github.com/e2b-dev/infra)** sandbox
cluster (Apache-2.0) on customer-owned Linux hosts — bare metal or nested-virt VMs — with no GCP/AWS dependency.
Kodus needs E2B because its only alternative (`SANDBOX_PROVIDER=local`) executes cloned third-party repos on the worker
host with **no isolation** (binary allowlist only); `e2b` mode gives a Firecracker microVM per review job.

Upstream E2B ships tooling only for GCP/AWS (Terraform + Nomad), but research against `e2b-dev/infra@6e4ce14`
(Aug 2026) established:

- E2B's own CI runs a **Nomad-free, cloud-free single node** (`.github/actions/{host-init,start-databases,start-services}`):
  `STORAGE_PROVIDER=Local`, `ARTIFACTS_REGISTRY_PROVIDER=Local`, `SERVICE_DISCOVERY_PROVIDER=local`, plain processes,
  `LOKI_URL=unset`. That is our reference recipe.
- Storage/registry/discovery are abstracted in code (Local FS, S3-compatible with `endpoint=` + path-style, Azure; local
  Docker daemon registry). Cloud coupling lives only in `iac/`.
- Kodus never passes `domain` to the E2B SDK; the SDK (`e2b@2.46.1`, `connectionConfig.ts`) reads `E2B_DOMAIN` /
  `E2B_API_URL` / `E2B_SANDBOX_URL` from env; Kodus's compose passes the whole env file to the worker; the E2B API never
  returns `domain` for the local cluster, so the SDK falls back to `E2B_DOMAIN`. **Redirecting Kodus to our cluster is
  config-only** — Phase 0 proves it end-to-end.
- Gotchas found and handled below: orchestrator is **glibc-dynamic**; API binary embeds the **expected migration
  timestamp**; CI omits `net.ipv4.ip_forward=1`; E2B API/orchestrator/client-proxy and Kodus's published ports bind
  `0.0.0.0` and E2B's sandbox firewall denies private ranges but **not the host's public IP**; per-node start limit is a
  compile-time flag; paused snapshots on Local FS are never garbage-collected; the upstream seeder is interactive and
  **destructive on re-run**; Kodus's published E2B template bakes in a Kodus-Cloud shadowsocks proxy that must be stripped.

## Decisions (from requirements grilling)

| Topic | Decision |
|---|---|
| Coupling | Kodus uses self-hosted E2B (`SANDBOX_PROVIDER=e2b`) |
| Hosts | Mixed per customer: bare metal and nested-virt VMs; **x86_64 only** |
| Distros | "Any" long-term; v1 CI matrix = **Ubuntu 24.04, Ubuntu 26.04, Fedora 44**. Installer may **require systemd, glibc, Docker Engine, root, KVM** (preflight aborts otherwise) |
| Topology | **Single node** for v1; multi-node later → Nomad+Consul (E2B native), no discovery patch needed |
| Scale | Medium: 50–500 PRs/day, repos 100k–1M LOC |
| Storage | Selectable: Local FS (default) / S3-compatible (MinIO, Ceph RGW) / NFS mount |
| Egress | Full internet (proxy optional). Sandboxes keep **E2B's default policy** (internet allowed, RFC1918/CGNAT/loopback denied); the host is protected by our own nftables ruleset |
| Git providers | GitHub.com, GitLab.com, Bitbucket Cloud, Azure DevOps, Forgejo/Gitea → public webhook URL required |
| LLM | Per customer: cloud API keys or on-prem OpenAI-compatible endpoint |
| DNS/TLS | Wildcard DNS available; TLS modes **ACME DNS-01 / customer-provided cert / internal CA** — all three |
| E2B builds | **QuantumOps CI builds a pinned commit** with a **patch overlay** (`e2b.pin` + `patches/`) |
| Orchestrator | **Host process under systemd** (root), as upstream does with Nomad `raw_exec` |
| Installer | **Ansible roles + thin bootstrap script** |
| Observability | Expose to customer's stack (OTLP/Prometheus endpoints); no bundled Grafana |
| Datastores | Bundled Docker containers only |
| Operations | QuantumOps remote-managed *and* customer self-operated; backups/restore + upgrades automated; remote access out of scope (documented) |
| Kodus edition | Community (license-key slot kept optional) |
| Dev hardware | Proxmox/cloud VM with nested virt (available now) |
| Milestone 1 | **Feasibility spike on the VM, then the installer end-to-end on Ubuntu 24.04** |

## Target architecture (single node)

```
                 Internet / Git-provider webhooks / LLM APIs            host nftables: input drop; allow 22,80,443
                                  │                                     veth-* → host: only 5010-5012, 5016-5018
                          :443/:80 Traefik (host, systemd)  ── TLS: acme_dns | provided | internal_ca
  kodus.<d>  kodus-api.<d>  kodus-webhooks.<d>          api.e2b.<d>           *.e2b.<d> (49983-<sbx>.e2b.<d>)
       │          │              │                          │                     │
 ┌─────┴──────────┴──────────────┴──────┐           ┌───────┴──────┐      ┌───────┴──────┐
 │ Kodus (Docker Compose, kodus-installer│  E2B SDK  │ e2b-api      │      │ client-proxy │ (static Go, systemd)
 │  + our compose override)              ├──────────▶│ 127.0.0.1:8080│     │ :3002 / :3003│
 │ web:3000 api:3001 webhooks:3332       │           │ :5009 gRPC   │      └───────┬──────┘
 │ worker: SANDBOX_PROVIDER=e2b          │           └───────┬──────┘              │ :5007
 │   E2B_DOMAIN=e2b.<d>  API_E2B_KEY     │                   │ gRPC :5008   ┌──────┴───────────────────┐
 │ rabbitmq  postgres16+pgvector  mongo8 │                   └─────────────▶│ e2b-orchestrator (root)  │
 └───────────────────────────────────────┘                                  │ + template-manager       │
  E2B datastores (compose): postgres:18 (127.0.0.1:5433)                    │ Firecracker microVMs     │
  redis:8  clickhouse 25.8  otel-collector (metrics→ClickHouse, OTLP out)   │ /fc-* /orchestrator NVMe │
                                                                            └──────────────────────────┘
  Template/snapshot store: file:///var/lib/e2b/storage | s3://bucket?endpoint=…&s3ForcePathStyle=true | NFS mount
```

Preflight-enforced host: x86_64, `/dev/kvm` (native or nested), cgroup v2 with `cpu` + `memory` in
`cgroup.subtree_control`, systemd, glibc ≥ 2.36, kernel ≥ 6.1 with `nbd` module loadable for the **running** kernel,
≥ 8 vCPU / 32 GB / 200 GB (NVMe preferred), Docker Engine present or installable, ports 22/80/443 free, `api.e2b.<d>`
and a random `x.e2b.<d>` resolve to a host IP, egress to ghcr.io / Docker Hub / LLM endpoint / bun.sh / npm.

**Bind policy:** only Traefik listens on `0.0.0.0` (80/443). Every other port — E2B api `--port 8080`, gRPC 5009/5109,
orchestrator 5007/5008, client-proxy 3002/3003, otel 4317/13133, and **all Kodus/E2B published container ports** — is
either bound to `127.0.0.1` (compose override) or dropped by the host nftables input chain (Go services that hardcode
`0.0.0.0`). Sandbox veths may only reach the orchestrator's REDIRECT targets (hyperloop/NFS/portmapper/TCP-firewall
ports 5010–5012, 5016–5018). `e2b_allow_sandbox_internal_cidrs` → `ALLOW_SANDBOX_INTERNAL_CIDRS` for customers with git
hosts on private IPs. E2B Postgres publishes on 5433 (Kodus Postgres owns 5432).

## Repository layout (init a git repo in this directory)

```
codereviewer/
├── versions.yml                 # all pins: kodus_installer_ref, kodus_image_tag, e2b_pin (sha), e2b_dist_version,
│                                # firecracker_version=v1.14-0.2.0, kernel_version=vmlinux-6.1.158-c1a568c, busybox=1.36.1
├── e2b/
│   ├── e2b.pin                  # upstream e2b-dev/infra commit SHA
│   ├── patches/                 # git patches applied in CI (starts empty; first candidate: env override for
│   │                            #   max-starting-instances-per-node / max-sandboxes-per-node fallbacks)
│   ├── build/                   # Dockerfile.build (golang:1.26.6-bookworm, glibc 2.36) + build.sh → dist tarball
│   └── templates/               # base + kodus-sandbox(+graph) template definitions (SDK v2) + build-templates.ts
├── ansible/
│   ├── inventory/example.yml
│   ├── group_vars/all.yml       # every variable, documented defaults
│   ├── playbooks/{preflight,site,upgrade,backup,restore,doctor,uninstall}.yml
│   └── roles/{preflight,common,host_firewall,docker,e2b_host,e2b_datastores,e2b_services,e2b_templates,
│              traefik,kodus,backup,doctor}
├── bootstrap.sh                 # installs ansible via pipx on the control host (or the target itself), runs site.yml
├── ci/                          # .github/workflows: build-e2b.yml, installer-matrix.yml, restore-drill.yml
└── docs/                        # architecture, install, operations runbooks, upgrade, backup-restore, security,
    │                            # remote-access, distro-notes/{ubuntu-24.04,ubuntu-26.04,fedora-44}.md, spike-notes.md
    └── superpowers/specs/2026-08-28-kodus-e2b-selfhost-design.md   # this plan, committed
```

## Phase 0 — Feasibility spike (manual, on the nested-virt VM)

Goal: prove the unverified links before writing installer code. Everything is throwaway except `docs/spike-notes.md`.

VM: Ubuntu 24.04, CPU type `host` with nested virt, ≥ 8 vCPU, 32 GB, 200 GB. Kodus + E2B on the same VM.

1. Host prep = `.github/actions/host-init/init-client.sh` **plus** `sysctl net.ipv4.ip_forward=1`, minus the CI-only
   `/mnt/snapshot-cache` tmpfs: dirs `/orchestrator/{sandbox,template,build}`, `/fc-vm`, `/fc-envd`, `/fc-kernels`,
   `/fc-versions`, `/fc-busybox`; `mount -t hugetlbfs none /mnt/hugepages` + `nr_hugepages`/`nr_overcommit_hugepages`
   split; `modprobe nbd nbds_max=4096` + udev rule `97-nbd-device.rules` (`OPTIONS:="nowatch"`); sysctls
   (`vm.max_map_count=1048576`, somaxconn/backlogs, `vm.swappiness=10`, `nf_conntrack_max`); `ulimit -n 1048576`;
   swapfile; Docker Engine; `iptables` + `nftables` userland.
2. Artifacts over plain HTTPS from `https://storage.googleapis.com/e2b-artifact-binaries/`, mirroring the bucket layout
   exactly (`fc/config.go` looks for `<dir>/<ver>/amd64/<file>` first):
   `firecrackers/v1.14-0.2.0/amd64/firecracker` → `/fc-versions/v1.14-0.2.0/amd64/firecracker`,
   `kernels/vmlinux-6.1.158-c1a568c/amd64/vmlinux.bin` → `/fc-kernels/vmlinux-6.1.158-c1a568c/amd64/vmlinux.bin`,
   `busybox/1.36.1/amd64/busybox` (+ `.sha256`) → `/fc-busybox/1.36.1/amd64/busybox`. `chmod -R 755`.
3. Build from the pinned commit with Go 1.26.6: `make -C packages/{orchestrator,api,client-proxy,envd} build` (release
   targets; `envd` static → `/fc-envd/envd`), plus `go build` of `packages/db/scripts/seed/postgres/seed-db.go` and a
   static `goose`. Record the migration timestamp baked into `api`.
4. Datastores: `postgres:18`, `redis:8` (`appendonly yes`), `clickhouse/clickhouse-server:25.8.30.16`,
   `otel/opentelemetry-collector-contrib:0.146.0` (CI config: metrics → ClickHouse). `CREATE SCHEMA IF NOT EXISTS extensions;`
   → `goose up` (postgres) → `goose clickhouse up`.
5. Seed team + API key (`seed-db` with the email on stdin; copy the printed `e2b_…` key) and insert an `addons` row for
   extra concurrency (see **E2B bootstrap**).
6. Start in order with CI env (`ENVIRONMENT=local`, `SERVICE_DISCOVERY_PROVIDER=local`, `LOCAL_ORCHESTRATOR_ADDRESS=127.0.0.1:5008`,
   `STORAGE_PROVIDER=Local` + `LOCAL_TEMPLATE_STORAGE_BASE_PATH`/`LOCAL_BUILD_CACHE_STORAGE_BASE_PATH`,
   `ARTIFACTS_REGISTRY_PROVIDER=Local`, `LOKI_URL=unset`, `ORCHESTRATOR_SERVICES=orchestrator,template-manager`,
   `ENVD_TIMEOUT=60s`, `REDIS_URL=localhost:6379`, `CLICKHOUSE_CONNECTION_STRING`, `API_INTERNAL_GRPC_ADDRESS=localhost:5009`,
   `SANDBOX_ACCESS_TOKEN_HASH_SEED`, `AUTH_PROVIDER_CONFIG='{"jwt":[]}'`, `VOLUME_TOKEN_ENABLED=false`, `NODE_ID`,
   `NODE_IP`, `DEFAULT_FIRECRACKER_VERSION=v1.14-0.2.0` and `DEFAULT_KERNEL_VERSION=vmlinux-6.1.158-c1a568c` **in both
   api and orchestrator env**, `SHARED_CHUNK_CACHE_PATH` unset): otel → orchestrator (root) → api `--port 8080` →
   client-proxy. Health: `:13133/healthz`, `:5008/health`, `:8080/health` (503 until a node is discovered), `:3003`.
7. Build templates against `E2B_API_URL=http://127.0.0.1:8080` (TLS off the critical path): `base`
   (`Template().fromBaseImage()`, 512 MB) and a stripped Kodus template = `Template().fromBaseImage().aptInstall(['git','ripgrep'])`
   — **no** shadowsocks `runCmd`, no `copy(config.json)`, no `setStartCmd(... waitForPort(12345))` — as aliases
   `kodus-sandbox` (2 vCPU/1024 MB) and `kodus-sandbox-graph` (2 vCPU/2560 MB).
8. Traefik with a lab wildcard (`*.e2b.lab.<domain>` via ACME DNS-01): `api.e2b.<d>` → :8080, `*.e2b.<d>` → :3002.
   `Host` preserved verbatim, WebSocket passthrough, no buffering, ≥ 16 MiB bodies on `api.`, `*.e2b` timeouts 24 h,
   upstream idle < 610 s. Verify with `curl` + the SDK from another machine.
9. Kodus via `kodustech/kodus-installer` (`scripts/install.sh`) with `.env` overrides:
   `SANDBOX_PROVIDER=e2b`, `API_E2B_KEY=<key>`, `E2B_DOMAIN=e2b.<d>`, `API_E2B_TEMPLATE_ID=kodus-sandbox`,
   `API_E2B_TEMPLATE_GRAPH_ID=kodus-sandbox-graph`, `E2B_PROXY_HOST` **unset**, `WORKER_ROLE=code-review`,
   `API_RABBITMQ_ENABLED=true`, `API_CLOUD_MODE=false`, `IMAGE_TAG=<pinned>`, LLM key,
   `API_GITHUB_CODE_MANAGEMENT_WEBHOOK=https://kodus-webhooks.<d>/github/webhook`, `WEB_HOSTNAME_API` (hostname only),
   `NEXTAUTH_URL`, `API_FRONTEND_URL`, `API_USER_INVITE_BASE_URL`. Record how the web container composes the API URL
   (`WEB_PORT_API`/scheme) — unverified. Connect a canary GitHub repo (GitHub App or fine-grained PAT), open a PR.
10. Exit criteria (all must pass; record numbers in `docs/spike-notes.md`):
    - E2B API request log shows the sandbox created by the Kodus worker on **our** API; worker logs never show
      `falling back to default` (`usedTemplate=false`).
    - Review comment posted **with cross-file/AST context** (graph stage ran; `bun install -g @kodus/kodus-graph@0.3.0`
      inside the sandbox succeeded → sandbox internet egress OK).
    - A ≥ 700 s streamed `commands.run` through the public hostname survives Traefik → client-proxy; WebSocket `/ws` works.
    - Isolation probe from inside a sandbox: `curl -m3 http://<host-public-ip>:5008/health` fails,
      `https://registry.npmjs.org` succeeds, `http://<lan-ip>` fails.
    - Pause on the 35-min timeout + `autoResume` reconnect works; `Sandbox.kill` of a paused sandbox — record what stays
      under `LOCAL_TEMPLATE_STORAGE_BASE_PATH` (feeds the GC design).
    - 10 parallel reviews: observe `max-starting-instances-per-node=3` and the tier concurrency cap; note queueing.
    - `systemctl restart e2b-orchestrator` under load: startup reclaim leaves no `ns-*`/`veth-*`/nbd/cgroup leaks.
    - Timings on nested virt: sandbox cold start, template build time, full review latency for a ~100k-LOC repo; whether
      the host-kernel ≥ 6.1 Firecracker mitigation (`kvm.nx_huge_pages=never`) was needed.
    - Note whether `ENVIRONMENT=prod` + explicit `SERVICE_DISCOVERY_PROVIDER=local` also works (`local` flips ~9 feature
      flags to dev defaults and disables the orchestrator single-instance lock).

If step 9 fails because the SDK still targets e2b.app, the fallback is a 2-line Kodus patch (pass `domain` in the two
`Sandbox.create` calls in `libs/sandbox/infrastructure/providers/e2b-sandbox.service.ts`) — then Kodus images must
be built by us; decide only after the spike.

## Phase 1 — E2B build pipeline (`e2b/`, `ci/build-e2b.yml`)

- `e2b/e2b.pin` = the commit validated in Phase 0. `patches/` starts empty.
- `Dockerfile.build` on `golang:1.26.6-bookworm` (glibc 2.36 ≤ every target host): clone upstream at pin,
  `git apply patches/*`, build `orchestrator` (CGO, `build-local` target), `api` (`CGO_ENABLED=0`, ldflags include
  `expectedMigrationTimestamp`), `client-proxy`, `envd` (static), `e2b-seed` (from
  `packages/db/scripts/seed/postgres/seed-db.go`), `clean-nfs-cache`, and a static `goose`
  (`go build github.com/pressly/goose/v3/cmd/goose` inside the module graph).
- Output `dist/e2b-<pin7>.tar.gz`: `bin/*`, `migrations/postgres/*.sql`, `migrations/clickhouse/*.sql`,
  `otel-collector.yaml`, `SHA256SUMS`, `BUILD_INFO` (pin, patch list, migration timestamp, envd version). Published as a
  GitHub Release asset (or your artifact bucket); Ansible downloads by `e2b_dist_version` and verifies checksums.
- Mirror third-party artifacts into the same release (installs must not depend on E2B's bucket staying public):
  firecracker `v1.14-0.2.0`, kernel `vmlinux-6.1.158-c1a568c`, busybox `1.36.1`, in the `<ver>/amd64/` layout.
  Optional: mirror `e2bdev/base` into the customer registry and reference it by full name in the template
  (bypasses Docker Hub anonymous rate limits; the build node pulls base images directly from Docker Hub otherwise).
- "Pin bump" workflow (monthly / on demand): rebuild, run the CI matrix, open a PR updating `versions.yml`.
  A dist bump that changes envd/kernel/Firecracker pins requires template rebuilds (feature gating keys on
  `env_builds.envd_version`) — `upgrade.yml` handles it.

## Phase 2 — Ansible installer, Ubuntu 24.04 first (`ansible/`)

Roles in `site.yml` order (ordering matters: templates need a healthy api+orchestrator; Kodus needs templates; TLS is
not on the template-build path because builds go to `http://127.0.0.1:8080`):

1. **preflight** — hard-fails with a report (`/etc/qops/preflight.json`): arch, `/dev/kvm` (+ nested flag on VMs),
   cgroup v2 with `cpu`/`memory` in `/sys/fs/cgroup/cgroup.subtree_control`, systemd, glibc ≥ 2.36, kernel ≥ 6.1 and
   `modprobe -n nbd` for the running kernel, hugetlbfs, RAM/CPU/disk minimums, ports 22/80/443 free, DNS checks,
   Docker repo reachability for the distro (`download.docker.com/linux/{ubuntu,fedora}`), egress checks.
2. **common** — packages by family (apt: `iptables nftables curl jq uuid-runtime nfs-common chrony`; dnf:
   `iptables-nft nftables …` + `kernel-modules-extra`), `sysctl.d` (`net.ipv4.ip_forward=1`, CI set,
   `nf_conntrack_max=2097152`), `limits.conf`, journald size caps, chrony, unattended-upgrades with
   `Automatic-Reboot=false` (kernel updates must be operator-driven: `nbd` module + KVM + hugepages), `/etc/qops`,
   `/var/lib/e2b`, `/var/backups/qops`, `/etc/qops/secrets.env` (0600) with generated E2B API key placeholder,
   `SANDBOX_ACCESS_TOKEN_HASH_SEED`, DB passwords.
3. **host_firewall** — single nftables ruleset on all distros (firewalld disabled on Fedora; Docker's own chains
   coexist): `inet filter input` policy drop; allow lo, established, 22, 80, 443; from `iifname "veth-*"` allow only
   dports 5010–5012 and 5016–5018; forward chain untouched (orchestrator manages per-slot NAT/MASQUERADE and the
   per-sandbox nftables deny list). `e2b_allow_sandbox_internal_cidrs` documented for private git hosts.
4. **docker** — Docker Engine + compose plugin from the vendor repo; `daemon.json` (log rotation; default address pools
   kept away from `sandbox_host_cidr` `10.11.0.0/16` / `sandbox_vrt_cidr` `10.12.0.0/16`, both variables).
5. **e2b_host** — `modprobe.d/nbd.conf` (`nbds_max=4096`) + `modules-load.d`, udev rule; hugetlbfs + swap +
   `/orchestrator` (`e2b_data_device` XFS or a directory) in fstab with `nofail`; a oneshot `e2b-hugepages.service`
   (before `docker.service`) computing the 80/20 split from `e2b_hugepages_percentage`; `/fc-*` artifacts from the release
   tarball in the `<ver>/amd64/` layout, checksums verified.
6. **e2b_datastores** — compose project `e2b-data` bound to `127.0.0.1`: postgres:18 (:5433, volume), redis:8
   (`appendonly yes`), clickhouse (add `MODIFY TTL` on metrics tables, `e2b_clickhouse_retention_days`),
   otel-collector (metrics → ClickHouse; OTLP receiver exposed on `127.0.0.1` for customer scrapers); healthchecks.
7. **e2b_services** — untar dist to `/usr/local/lib/e2b/<version>` + `current` symlink; env files
   `/etc/qops/e2b/{orchestrator,api,client-proxy}.env`; `goose up` (pg + clickhouse) idempotently; **seed** via
   `bin/e2b-seed` gated on `SELECT 1 FROM teams WHERE email=$1` (never a file marker — the seeder deletes that team's
   envs/snapshots on re-run); insert the concurrency `addons` row; systemd units:
   - `e2b-orchestrator`: root, `Requires=docker.service After=docker.service network-online.target`,
     `RequiresMountsFor=/orchestrator /mnt/hugepages`, `LimitNOFILE=1048576 LimitMEMLOCK=infinity TasksMax=infinity
     OOMScoreAdjust=-900 TimeoutStopSec=180`, `ORCHESTRATOR_LOCK_PATH=/orchestrator/orchestrator.lock`,
     **no** `ProtectSystem/PrivateDevices/ProtectControlGroups/RestrictNamespaces/ProtectKernelTunables` (needs
     `/dev/kvm`, `/dev/net/tun`, `/dev/nbd*`, `/run/netns`, `/sys/fs/cgroup/e2b`, hugetlbfs, iptables/nft). Firecracker
     processes live in `/sys/fs/cgroup/e2b/sbx-*` outside the unit cgroup: `systemctl stop` drains live sandboxes
     (up to the 35-min ceiling) unless `FORCE_STOP=true`, which `upgrade.yml` sets.
   - `e2b-api` (`--port 8080`, unprivileged user), `e2b-client-proxy` (unprivileged user); both `After=e2b-orchestrator`.
   Wait on `:5008/health`, `:8080/health`, `:3003`.
8. **e2b_templates** — Node 22 + `e2b` SDK on the host (or a one-shot container); `build-templates.ts` against
   `E2B_API_URL=http://127.0.0.1:8080` builds `base`, `kodus-sandbox`, `kodus-sandbox-graph`; always rebuilds on
   `upgrade.yml`, skipped on `site.yml` re-runs when the aliases exist (`Template.exists`). Kodus references **aliases**,
   so no ID bookkeeping. Prunes stale `templateId:buildId` images from the Docker daemon (the Local registry never deletes).
9. **traefik** — static binary + systemd; entrypoints 80/443; routers `api.e2b.<d>`→:8080 (priority 500),
   `*.e2b.<d>`→:3002 (catch-all, priority 100), `kodus.<d>`→:3000, `kodus-api.<d>`→:3001, `kodus-webhooks.<d>`→:3332
   (own host, as upstream docs recommend — the webhook server serves `/github/webhook` etc. at root).
   Transport mirrors upstream's LB: `Host` unchanged, no buffering, `respondingTimeouts` read/write 0 and idle 24 h on
   `websecure`, `serversTransport.forwardingTimeouts.idleConnTimeout=600s` (< client-proxy's 610 s),
   `responseHeaderTimeout=0`, WebSocket passthrough, body limit ≥ 16 MiB on `api.e2b`.
   `tls_mode: acme_dns|provided|internal_ca`: built-in lego DNS-01 (`tls_acme_dns_provider` + creds), or file-provider
   certs (`tls_cert_path`/`tls_key_path`); `internal_ca` additionally installs `tls_ca_path` into the host trust store,
   mounts it into Kodus containers with `NODE_EXTRA_CA_CERTS`, and into the template-build client. Waits until
   `https://api.e2b.<d>/health` answers **from inside a container on the Kodus network** (hairpin check).
10. **kodus** — clone `kodustech/kodus-installer` at `kodus_installer_ref`; create the three external Docker networks;
    render `.env` = upstream `.env.example` + `kodus_env_overrides` (E2B block with aliases, LLM block:
    `API_LLM_PROVIDER_MODEL`, `API_OPEN_AI_API_KEY` (Anthropic keys go in the same slot), `API_OPENAI_FORCE_BASE_URL`
    for vLLM; per-provider `API_<PROVIDER>_CODE_MANAGEMENT_WEBHOOK`; `WEB_HOSTNAME_API`, `NEXTAUTH_URL`,
    `API_FRONTEND_URL`, `API_USER_INVITE_BASE_URL`, `API_MCP_MANAGER_REDIRECT_URI`, `API_KODUS_MCP_SERVER_URL`;
    `KODUS_TELEMETRY_DISABLED` (variable); optional `KODUS_LICENSE_KEY`; `IMAGE_TAG=<kodus_image_tag>`); drop in
    `docker-compose.override.yml` (no fork: `restart: unless-stopped` for the DB containers, `127.0.0.1:` port binds,
    `:z` on bind mounts, `extra_hosts` for hairpin if needed, CA mount); run `scripts/generate-secrets.sh` once
    (persisted); run upstream `scripts/install.sh` (validates required vars, starts the right service set); wait on
    `/health`; run `scripts/doctor.sh`; print the GitHub App / OAuth callback URLs the operator must register.
11. **backup** — `qops-backup` script + timer: `pg_dump` (Kodus PG, E2B PG), `mongodump`, RabbitMQ definitions export,
    `/etc/qops`, template store (rsync/restic for Local/NFS; document bucket-native backup for S3); retention;
    optional off-box target (`backup_target: local|s3|rsync`); `restore.yml` restores from a bundle. Also installs
    `qops-e2b-gc` (timer): prune unreferenced paused-snapshot dirs (see **E2B bootstrap**) and stale template images.
12. **doctor** — `qops-doctor`: preflight re-check, unit health, hugepages free, nbd devices in use, `nbd.ko` present for
    the newest installed kernel, disk/store usage, Kodus health + RabbitMQ queues, **E2B smoke test** (create sandbox
    from `kodus-sandbox`, `echo ok`, isolation probe, kill), webhook reachability probe from outside, grep worker logs
    for `falling back to default`. Non-zero exit with a summary.

Playbooks: `preflight.yml`, `site.yml`, `upgrade.yml` (backup → fetch new dist/images per `versions.yml` → stop with
`FORCE_STOP=true` → migrate → start → rebuild templates if pins changed → doctor), `backup.yml`, `restore.yml`,
`doctor.yml`, `uninstall.yml` (also removes E2B's nft tables, `/run/netns/ns-*`, `veth-*`, `/sys/fs/cgroup/e2b`).
`bootstrap.sh`: `curl | bash`-style entry that installs pipx+ansible on the control host (or the target) and runs `site.yml`.

## Phase 3 — Kodus template + wiring details

- `e2b/templates/kodus-template.ts` as in Phase 0 step 7; parametrised base image (`e2bdev/base` or mirrored name).
- Kodus compose is upstream's; we do not fork Kodus. Additions are env keys the SDK reads (`E2B_DOMAIN`, optionally
  `E2B_SANDBOX_URL`, `NODE_EXTRA_CA_CERTS`) plus the compose override.
- Hairpin: the worker must resolve `api.e2b.<d>` and `49983-*.e2b.<d>` to the host's public IP and reach Traefik. If a
  customer network breaks hairpin NAT, set `E2B_API_URL=https://api.e2b.<d>` + `E2B_SANDBOX_URL=https://sandbox.e2b.<d>`
  (client-proxy header routing accepts `sandbox.<any-domain>`) and add `extra_hosts` for those two names.

## Phase 4 — Upgrades, backups, docs

- `versions.yml` is the only file bumped for an upgrade; `upgrade.yml` enforces: backup first; E2B API binary and
  migrations from the same dist (API refuses to start against an older DB); Kodus `IMAGE_TAG` pinned (never `latest`);
  Kodus migrations run only by the `api` container (upstream constraint); templates rebuilt when envd/kernel/FC pins change.
- Docs: `install.md` (per-customer inputs: domain, DNS, TLS mode, git provider credentials, LLM provider),
  `operations.md` runbooks (sandbox stuck, hugepages exhausted, nbd exhaustion, RabbitMQ `QueueBind 404`, webhook silent
  failure, Docker Hub rate limit during template build, Redis restart orphaning the running-sandbox catalog, E2B API-key
  rotation), `security.md` (what runs as root, bind policy, sandbox network policy, data locations), `remote-access.md`
  (Tailscale / bastion / customer-run options), distro notes.

## Phase 5 — CI matrix (`ci/installer-matrix.yml`)

- **Ubuntu 24.04**: GitHub-hosted `ubuntu-24.04` runner has KVM (E2B's own `fc-test.yml` boots Firecracker there):
  `bootstrap.sh` against localhost → `doctor.yml` → Kodus E2E smoke (webhook delivered via a `cloudflared` tunnel or a
  synthetic webhook POST to a canary repo).
- **Ubuntu 26.04** and **Fedora 44**: self-hosted runners = Proxmox VMs with nested virt, reset from snapshot per run.
- **Fedora 44 expected work**: `docker-ce` from `download.docker.com/linux/fedora` (preflight confirms the 44 repo);
  SELinux enforcing (`:z` bind mounts; orchestrator is an unconfined root host process); **firewalld disabled** in favour
  of our nftables ruleset; `iptables-nft` for `go-iptables`; `nbd` from `kernel-modules-extra` (per-kernel — doctor
  checks the newest installed kernel); newer host kernel → verify the Firecracker mitigation.
- **Ubuntu 26.04**: `linux-modules-extra-$(uname -r)` metapackage for `nbd`; otherwise identical to 24.04.
- `restore-drill.yml` (weekly): install → seed data → backup → wipe → restore → doctor.

## E2B bootstrap (first-run identity) — verified against upstream

Upstream `make prep-cluster` = `packages/db/scripts/seed/postgres/seed-db.go` + `packages/shared/scripts/build.prod.ts`.
Our installer reproduces it non-interactively:

1. **Seed** — `bin/e2b-seed` (upstream seeder built in CI; email on stdin; prints `Team API Key: e2b_<40 hex>` once).
   Run only when `SELECT 1 FROM teams WHERE email=$1` is empty — the script **deletes envs/snapshots/addons/teams for
   that email on every run**. It creates `auth.users`, `public.users`, `teams` (tier `base_v1`, slug `e2b`),
   `users_teams`, `team_api_keys` (SHA-256 of the 20 raw key bytes stored as `$sha256$<base64>` — never hand-insert keys
   via SQL). Plaintext key → `/etc/qops/secrets.env`. Access tokens (`sk_e2b_`) no longer exist; the API key
   authenticates both `Sandbox.create` and `Template.build()` (`X-API-Key`).
2. **Limits** (pure SQL, no LaunchDarkly). Effective limits = `team_limits` view = `COALESCE(project_limits, tiers + addons)`.
   `base_v1`: `concurrent_instances=20`, `max_length_hours=1`, `max_vcpu=8`, `max_ram_mb=8096`, `max_disk_size_mb=25600`.
   Installer inserts an `addons` row (`extra_concurrent_sandboxes = e2b_max_concurrent_sandboxes - 20`, default total
   100; `extra_concurrent_template_builds`). Kodus's 35-min timeout fits the 1 h cap; `e2b_max_sandbox_hours` (default 1)
   updates `tiers.max_length_hours` only if raised.
3. **Templates** — built by role `e2b_templates` after api+orchestrator are healthy: `base` (512 MB; Kodus's fallback),
   `kodus-sandbox` (2 vCPU/1024 MB), `kodus-sandbox-graph` (2 vCPU/2560 MB). Per-sandbox CPU/RAM is fixed at build time
   (`NewSandbox` has no cpu/ram fields). Builds run on the host, so `LOCAL_UPLOAD_BASE_URL` stays at its default
   `http://localhost:5008`; document `upload.e2b.<d>` → `:5008/upload` only for remote builds with `COPY` steps.
4. **Domain** — the API never returns `domain` for the local cluster (`clusters_sync.go` `localClusterConfig()`), so the
   SDK uses `E2B_DOMAIN`; there is no `SANDBOX_DOMAIN` env var.

Other verified constraints that shape the env files:

- API: `REDIS_URL=host:port` (no scheme) is **fatal if missing**; `NODE_ID` required on all three services; `LOKI_URL`
  must be non-empty (`unset` is upstream's own value; log queries degrade to empty arrays); `--port` is a CLI flag;
  `VOLUME_TOKEN_ENABLED=false` drops the four `VOLUME_TOKEN_*` vars; `AUTH_PROVIDER_CONFIG='{"jwt":[]}'` = API keys
  only; CORS allow-all is hardcoded; app-level rate limits are off.
- Orchestrator: `ENVD_TIMEOUT=60s` (resume wait for envd; CI value, nested virt is slow); `max-sandboxes-per-node=200`
  and **`max-starting-instances-per-node=3`** are compile-time LaunchDarkly fallbacks with no env override. If Phase 0
  shows throttling, the first `e2b/patches/` entry makes them env-overridable (upstream already does this for `ENVD_TIMEOUT`).
- Storage: paused-sandbox snapshots are written through the **template** storage provider under
  `LOCAL_TEMPLATE_STORAGE_BASE_PATH/<buildID>/` (memfile/rootfs **diffs** + headers + `.uncompressed-size` sidecars).
  **Nothing upstream deletes them on Local FS.** `qops-e2b-gc` removes `<buildID>` dirs not referenced by live
  `env_builds`/`snapshots` rows and older than `e2b_snapshot_retention_hours`; `doctor` reports store size.
- Postgres: ≥ 15 (`security_invoker` views); migrations need `CREATEROLE` and a role literally named `postgres` — the
  bundled container as superuser `postgres` satisfies this; `pgcrypto` is not required (schema `extensions` is).

## Key configuration reference

Kodus `.env` (self-hosted required + E2B block): `WEB_HOSTNAME_API` (hostname only), `NEXTAUTH_URL`,
`API_FRONTEND_URL`, `API_USER_INVITE_BASE_URL`, `API_<GITHUB|GITLAB|BITBUCKET|AZURE_REPOS|FORGEJO>_CODE_MANAGEMENT_WEBHOOK`,
`API_RABBITMQ_ENABLED=true`, `WORKER_ROLE=code-review`, `API_CLOUD_MODE=false`, `IMAGE_TAG`, secrets from
`generate-secrets.sh`, `SANDBOX_PROVIDER=e2b`, `API_E2B_KEY`, `E2B_DOMAIN`, `API_E2B_TEMPLATE_ID=kodus-sandbox`,
`API_E2B_TEMPLATE_GRAPH_ID=kodus-sandbox-graph`, LLM block, `KODUS_TELEMETRY_DISABLED`, optional `KODUS_LICENSE_KEY`.

E2B services env: `ENVIRONMENT=local`, `SERVICE_DISCOVERY_PROVIDER=local`, `LOCAL_ORCHESTRATOR_ADDRESS=127.0.0.1:5008`,
`NODE_ID`, `NODE_IP`, `ORCHESTRATOR_SERVICES=orchestrator,template-manager`, `ENVD_TIMEOUT=60s`,
`TEMPLATE_STORAGE_URL`/`BUILD_CACHE_STORAGE_URL` (or `STORAGE_PROVIDER=Local` + `LOCAL_*_BASE_PATH`),
`ARTIFACTS_REGISTRY_PROVIDER=Local`, `OTEL_COLLECTOR_GRPC_ENDPOINT=localhost:4317`, `REDIS_URL=host:port`,
`POSTGRES_CONNECTION_STRING`, `CLICKHOUSE_CONNECTION_STRING` (no stray `$localhost` typo from CI), `LOKI_URL=unset`,
`API_INTERNAL_GRPC_ADDRESS=localhost:5009`, `SANDBOX_ACCESS_TOKEN_HASH_SEED`, `AUTH_PROVIDER_CONFIG='{"jwt":[]}'`,
`VOLUME_TOKEN_ENABLED=false`, `DEFAULT_FIRECRACKER_VERSION=v1.14-0.2.0`, `DEFAULT_KERNEL_VERSION=vmlinux-6.1.158-c1a568c`
(both files), `SANDBOXES_HOST_NETWORK_CIDR`, `SANDBOXES_VRT_NETWORK_CIDR`, `ALLOW_SANDBOX_INTERNAL_CIDRS` (optional),
`MAX_PARALLEL_MEMFILE_SNAPSHOTTING`, `ORCHESTRATOR_LOCK_PATH=/orchestrator/orchestrator.lock`, api started with
`--port 8080`, no `LAUNCH_DARKLY_API_KEY`, no `NOMAD_*`, no `SHARED_CHUNK_CACHE_PATH`.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| `E2B_DOMAIN` redirect doesn't take in Kodus | Phase 0 gate; fallback = 2-line Kodus patch + own image build |
| E2B `main` churn breaks the pin/patches | Pin + CI rebuild + matrix before any bump; keep patches minimal |
| Kodus releases every ~4–5 days | Pin `IMAGE_TAG`; upgrade playbook tested in CI |
| Nested-virt performance | Measure in Phase 0; document bare-metal recommendation for medium load |
| Sandbox → host services (Kody's `exec` tool + prompt injection) | Bind policy + host nftables; isolation probe in doctor and CI |
| Docker Hub rate limits during template builds | Optional mirror of `e2bdev/base` to customer registry |
| Public webhook requirement behind customer NAT | Document Cloudflare Tunnel / reverse-proxy options |
| Fedora SELinux/firewalld unknowns | Dedicated matrix leg + distro notes; firewalld disabled by design |
| E2B sandbox/build logs empty with `LOKI_URL=unset` | Acceptable for v1 (Kodus doesn't read them); optional small Loki later |
| Local FS store growth (no upstream GC) | `qops-e2b-gc` timer + doctor report; kill/pause disk behaviour verified in Phase 0 |
| `max-starting-instances-per-node=3` throttles bursts | Measure in Phase 0; patch to env-overridable if needed |
| Seeder re-run wipes the team's envs/snapshots | DB-existence gate; never invoked by `upgrade.yml` |
| Kernel updates break nbd/KVM/hugepages | Unattended-upgrades never reboots; doctor checks `nbd.ko` for newest kernel; runbook |

## Milestone sequencing

- **M1** (this plan's first deliverable): Phase 0 spike → Phase 1 build pipeline → Phase 2 roles on Ubuntu 24.04 with
  `tls_mode` = `acme_dns` and `provided`, Local FS storage, `site.yml` + `doctor.yml` + `upgrade.yml`; Ubuntu 24.04 CI leg.
- **M2**: `internal_ca`, S3/NFS storage backends, `backup.yml`/`restore.yml` + restore drill, Fedora 44 + Ubuntu 26.04
  legs and distro notes, full runbooks.
- Deferred beyond v1: multi-node/HA (Nomad), ARM64, Kubernetes, bundled Grafana, LLM server deployment, Kodus
  Enterprise, Podman, musl distros, air-gapped bundles (artifacts are kept mirrorable so this can be added).

## Execution model — Sonnet 5 implements, Opus 5 reviews

Run with `superpowers:subagent-driven-development` from this session as controller. Model assignment is explicit on
every dispatch (never inherit the session model):

| Role | Model (`Agent` `model:`) | Notes |
|---|---|---|
| Implementer (one fresh subagent per task, never two in parallel, no sub-subagents) | **`sonnet`** (Sonnet 5) | Gets only the task brief, interfaces from earlier tasks, report-file path |
| Task reviewer (spec compliance + code quality, after every task) | **`opus`** (Opus 5) | Gets brief + report + review package (diff file) + Global Constraints verbatim |
| Scoped re-reviewer (fix rounds) | **`opus`** | Verdicts each finding ADDRESSED / NOT ADDRESSED |
| Fix-loop rounds 1–3 | resume the same Sonnet implementer | |
| Fix-loop rounds 4–5 | fresh implementer on **`opus`** | Breaker at round 5 → controller adjudicates and ledgers rulings |
| Final whole-branch review (per milestone) | **`opus`** | Uses `requesting-code-review` reviewer prompt; one fix wave, one scoped re-review |
| Research / spike script drafting | `sonnet` | Phase 0 is executed against the Proxmox VM over SSH (inventory provided by you); subagents draft scripts, the controller runs them and records `docs/spike-notes.md` |

Mechanics:
- **Task 0** (controller, before any dispatch): `git init` this directory, first commit with this design doc at
  `docs/superpowers/specs/2026-08-28-kodus-e2b-selfhost-design.md`, create a worktree per milestone
  (`superpowers:using-git-worktrees`), ledger at `.superpowers/sdd/<plan>/progress.md`.
- For each milestone, first produce the executable task plan with `superpowers:writing-plans`
  (`docs/superpowers/plans/2026-MM-DD-<milestone>.md`): every task lists exact files, interfaces consumed/produced, the
  failing test first, the command and expected output, and the commit — no placeholders. This design doc is the spec
  those plans argue from.
- **Global Constraints** handed to every reviewer: pins from `versions.yml`; bind policy (only Traefik on `0.0.0.0`);
  no Kodus fork (compose override + env only); E2B changes only via `e2b/patches/`; `IMAGE_TAG` never `latest`; seeder
  gated on DB query; template aliases not IDs; systemd units for the orchestrator carry no sandboxing directives;
  every role idempotent (second run = zero changes).
- **What subagents can test on this Mac** (no KVM): `ansible-lint`, `yamllint`, `ansible-playbook --syntax-check`,
  Jinja template rendering tests (`ansible-playbook --check` with `-e` fixtures), `bats` for shell scripts
  (`qops-doctor`, `qops-backup`, `qops-e2b-gc`, `bootstrap.sh`), `shellcheck`, Go/TS unit tests for
  `build-templates.ts`, Dockerfile.build via `docker build` (arm64 host builds x86_64 binaries with `GOARCH=amd64`).
  Integration proof comes from the VM (M1) and the CI matrix — task reviewers flag anything only claimed, never
  demonstrated.

M1 task list (each an independent dispatch; sizes guide model choice — all default to Sonnet 5):

| # | Task | Deliverable + test |
|---|---|---|
| 1 | Repo skeleton + `versions.yml` + `bootstrap.sh` | Layout above; `bats` test that `bootstrap.sh` installs pipx/ansible in a container and runs `--syntax-check` |
| 2 | `e2b/build/` pipeline | `Dockerfile.build` + `build.sh` produce `dist/e2b-<pin7>.tar.gz` with `SHA256SUMS`/`BUILD_INFO`; test: build from `e2b.pin`, assert every binary present, `api` migration timestamp equals newest migration file |
| 3 | `ci/build-e2b.yml` + artifact mirroring | Workflow builds dist, downloads FC/kernel/busybox into `<ver>/amd64/`, verifies `.sha256`, publishes release; test: `act`/dry-run job succeeds on a fixture pin |
| 4 | `e2b/templates/` | `kodus-template.ts`, `build-templates.ts` (aliases `base`, `kodus-sandbox`, `kodus-sandbox-graph`, `Template.exists` skip); unit tests with a mocked SDK |
| 5 | Roles `preflight`, `common`, `host_firewall`, `docker` | Preflight report JSON schema + failing-fixture tests; nftables ruleset rendered and validated with `nft -c -f` |
| 6 | Roles `e2b_host`, `e2b_datastores` | fstab/modprobe/udev/hugepages oneshot templates; compose file with `127.0.0.1` binds; healthcheck waits |
| 7 | Role `e2b_services` | Env-file templates from the config reference, three systemd units, goose migrations, DB-gated seed + addons SQL, health waits |
| 8 | Roles `e2b_templates`, `traefik` | Traefik static/dynamic config for `acme_dns` + `provided` (M1), routers/timeouts per Phase 2 step 9; hairpin health gate |
| 9 | Role `kodus` | `.env` render from upstream `.env.example` + overrides, `docker-compose.override.yml`, `install.sh` invocation, callback-URL summary |
| 10 | Role `doctor` + `doctor.yml` | `qops-doctor` (bats-tested with stubbed commands), E2B smoke + isolation probe, webhook probe |
| 11 | `upgrade.yml` + `qops-e2b-gc` + `uninstall.yml` | Pin-bump flow with `FORCE_STOP=true`, template rebuild condition, GC script tests against a fixture store + fake DB rows |
| 12 | `ci/installer-matrix.yml` (Ubuntu 24.04 leg) | GH-hosted runner: `bootstrap.sh` → `doctor.yml` → canary-PR smoke |
| 13 | Docs for M1 (`install.md`, `operations.md`, `security.md`, `spike-notes.md` template) | Reviewed by Opus 5 against this spec |

M2 tasks (internal CA, S3/NFS backends, backup/restore + drill, Fedora 44 + Ubuntu 26.04 legs, runbooks) get their own
writing-plans document after M1's final review.

## Verification

- Phase 0 exit criteria recorded in `docs/spike-notes.md`.
- `ansible-lint` + syntax checks on every PR.
- CI matrix from a clean snapshot: `site.yml` → `doctor.yml` green (E2B smoke + isolation probe + webhook probe) →
  Kodus posts a review on a canary PR **with cross-file context** → a 700 s streamed `commands.run` through the public
  hostname succeeds → reboot → `doctor.yml` green with no manual steps → `systemctl restart e2b-orchestrator` under load
  leaves no `ns-*`/veth/nbd/cgroup leaks → `upgrade.yml` from the previous `versions.yml` succeeds and a mismatched
  API/DB pair fails fast → second `site.yml` run reports zero changes and triggers no template build → (M2) weekly
  restore drill passes.
