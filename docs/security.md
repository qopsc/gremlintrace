# Security

**Status:** Security controls are implemented in Ansible roles as designed. **Threat-model validation on a live cluster (isolation probe under real prompt-injection load) has not been executed** — Phase 0 and `qops-doctor` define the intended verification.

## Threat model

Kodus’s review **agent executes untrusted repository content** inside sandboxes. A prompt-injected agent could attempt to reach host services (metadata APIs, orchestrator health, internal Docker ports). The deployment layers:

1. **Sandbox isolation** — Firecracker microVM per job (not `SANDBOX_PROVIDER=local`).
2. **Sandbox network policy** — E2B default deny for RFC1918/CGNAT/loopback; optional `e2b_allow_sandbox_internal_cidrs` for private git.
3. **Host bind policy** — Traefik 80/443 are the network-reachable listeners; E2B Go services hardcode `0.0.0.0` and are contained by nftables input-drop; datastore and Kodus ports on `127.0.0.1`.
4. **Host nftables** — Input drop except SSH/HTTP/HTTPS and orchestrator redirect ports from `veth-*`.
5. **Isolation probe** — `qops-doctor` creates a sandbox and asserts `:5008` and LAN targets are blocked while npm egress works.

Compromise of the host orchestrator (root) or Traefik still implies full host impact — design assumes orchestrator must remain root for KVM/nbd/netns.

## What runs as root

| Component | User | Why |
|---|---|---|
| `e2b-orchestrator` | root | Needs `/dev/kvm`, `/dev/net/tun`, `/dev/nbd*`, `/run/netns`, `/sys/fs/cgroup/e2b`, hugetlbfs, iptables/nft coordination |
| `traefik` | `traefik` | Binds 80/443; configs root-owned, state under `/var/lib/traefik` |
| `e2b-api`, `e2b-client-proxy` | `e2b` | Unprivileged after orchestrator brings up node |
| Kodus containers | container users | Upstream images |
| `qops-backup`, `qops-e2b-gc` | root | Reads `/etc/qops`, talks to Docker sockets |

The orchestrator unit **must not** carry systemd sandboxing directives (`ProtectSystem`, `PrivateDevices`, `RestrictNamespaces`, etc.) — Firecracker children live outside the unit cgroup under `/sys/fs/cgroup/e2b/sbx-*`.

## Bind policy

Network-reachable listeners are Traefik `0.0.0.0:80` and `0.0.0.0:443` only (`ansible/roles/traefik`). Kodus and E2B datastore ports are published on `127.0.0.1` via compose override (`ansible/roles/kodus`). E2B Go binaries hardcode `0.0.0.0` (upstream; no bind-address patch) and are contained by nftables (`ansible/roles/host_firewall` + `e2b_services` README). Those two facts are one policy: Traefik is the public edge; nftables input-drop is what keeps the Go `0.0.0.0` sockets off the network.

Preflight fails if ports 80/443 are taken by non-allowed processes before install.

## Sandbox network policy

Orchestrator sets per-sandbox nftables and NAT. Sandboxes reach the internet by default; private ranges blocked unless `e2b_allow_sandbox_internal_cidrs` is set (maps to `ALLOW_SANDBOX_INTERNAL_CIDRS` in orchestrator env).

Host input chain allows from `veth-*` only TCP dports 5010–5012 and 5016–5018 (hyperloop/NFS/portmapper/firewall redirects).

## Isolation probe

Configured via `qops_public_ipv4` (globally routable) and `qops_lan_ipv4` (RFC1918, distinct). Doctor:

1. Proves host listeners on orchestrator and LAN targets are live from the host.
2. From inside `kodus-sandbox`, asserts `http://<public>:5008/health` blocked, `https://registry.npmjs.org` allowed, `http://<lan>/` blocked.

Empty or invalid targets fail the probe (never silently pass).

## Secrets

| Location | Mode | Contents |
|---|---|---|
| `/etc/qops/secrets.env` | 0600 root | DB passwords, `E2B_API_KEY`, `SANDBOX_ACCESS_TOKEN_HASH_SEED`, generated placeholders |
| `/etc/qops/traefik-acme.env` | 0600 root | DNS-01 credentials (not merged into `secrets.env`) |
| `/etc/qops/e2b/*.env` | 0600 root | Service env with connection strings |
| `/etc/qops/kodus/generated-secrets.env` | 0600 root | Upstream Kodus secrets |
| `/opt/kodus-installer/.env` | 0600 root | Rendered Kodus config including LLM keys |
| `/etc/qops/e2b/seeded-api-key` | 0600 root | Durable E2B team API key plaintext (first seed only) |

Who can read: root and Ansible become user on the host. Container services receive only keys injected via compose env files. **Do not** expose `secrets.env` to unprivileged users or backup channels without encryption.

E2B team API keys in Postgres are stored hashed; plaintext exists only in `secrets.env` / `seeded-api-key`.

## E2B seeder safety

`bin/e2b-seed` runs only when no team row exists for `e2b_admin_email`. Re-running deletes that team’s envs and snapshots. `upgrade.yml` sets `e2b_services_seed_enabled: false`.

## CI secrets

`installer-matrix.yml` uses `QOPS_CI_LLM_API_KEY` and `QOPS_CI_CANARY_REPO_TOKEN` from GitHub Actions secrets (never exposed to fork PRs). Workflow does not use `pull_request_target`.

## Remote access

Out of scope for M1 (document customer bastion / Tailscale separately). SSH (22) is the only non-HTTP admin port allowed by default nftables input.

## Known gaps

- No automated E2B API key rotation (see `docs/operations.md`).
- `internal_ca` TLS mode not implemented in M1.
- Sandbox → host public IP path relies on nftables; host public IP is **not** in E2B sandbox deny list by design — probe verifies block from sandbox.
- Full adversarial review of prompt injection paths not completed (Phase 0 gate).
