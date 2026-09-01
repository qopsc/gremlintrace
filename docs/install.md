# Installation guide

**Status:** The Ansible roles and playbooks in this repository are implemented for M1, but **this installer has never been run on a real customer host.** Treat the steps below as the intended procedure; validate on your own lab before production. Phase 0 (`docs/spike-notes.md`) remains the gate for unproven integration assumptions.

## Audience

Operators installing codereviewer at a customer site. For role-level contracts see `ansible/roles/*/README.md`.

## Per-customer inputs

Collect before install:

| Input | Variable / location | Notes |
|---|---|---|
| Primary domain | `qops_domain` | e.g. `example.com` → `kodus.example.com`, `api.e2b.example.com` |
| Wildcard DNS | DNS provider | `api.e2b.<d>` and `*.e2b.<d>` must resolve to the host’s public IP |
| TLS mode | `tls_mode` | M1: `acme_dns` or `provided`. `internal_ca` is M2. |
| ACME DNS-01 | `tls_acme_dns_provider`, `/etc/qops/traefik-acme.env` | Credentials **not** in `secrets.env` |
| Provided cert | `tls_cert_path`, `tls_key_path` | Wildcard or SANs covering all hostnames above |
| Git provider | Kodus `.env` webhook URLs | One `API_<PROVIDER>_CODE_MANAGEMENT_WEBHOOK` per provider |
| GitHub App / OAuth | Register after install | URLs printed by the `kodus` role |
| LLM | `kodus_openai_api_key` / `kodus_openai_force_base_url` | Cloud key or on-prem OpenAI-compatible endpoint |
| E2B release | `qops_github_repository` or `qops_release_base_url` | Dist tag `e2b-<e2b_dist_version>` from `versions.yml` |
| Isolation probe IPs | `qops_public_ipv4`, `qops_lan_ipv4` | Globally routable public IP and distinct RFC1918 LAN IP for `qops-doctor` |
| Optional private git | `e2b_allow_sandbox_internal_cidrs` | Sandbox egress to on-prem forge hosts |

Secrets are generated into `/etc/qops/secrets.env` (mode `0600`) and Kodus `generated-secrets.env`; never commit them.

## Prerequisites

Preflight (`ansible/roles/preflight`) enforces on the target host:

- x86_64, systemd, glibc ≥ 2.36, kernel ≥ 6.1 with loadable `nbd`
- `/dev/kvm` (native or nested)
- cgroup v2 with `cpu` and `memory` in `cgroup.subtree_control`
- hugetlbfs available
- ≥ 8 vCPU, 32 GiB RAM, 200 GiB free on the orchestrator data path (defaults in `group_vars/all.yml`)
- Ports 22, 80, 443 free (or owned by allowed units after install)
- DNS checks for `api.e2b.<d>` and a random `*.e2b.<d>` label resolving to this host
- Egress to Docker registries, ghcr.io, bun.sh, npm, and your LLM endpoint

M1 supports **Ubuntu 24.04** only on Debian family (`ansible/roles/common` rejects other families). See `docs/distro-notes/ubuntu-24.04.md`.

## Command sequence

1. **Configure inventory** — copy `ansible/inventory/example.yml`, add the host under `codereviewer`, set `ansible_host`, `ansible_user`, `ansible_become`.

2. **Set variables** — edit `ansible/group_vars/all.yml` (or host vars): `qops_domain`, `tls_mode`, LLM keys via vault, `qops_public_ipv4` / `qops_lan_ipv4`, release URL if not using the default GitHub slug.

3. **Optional preflight only:**

   ```bash
   ./bootstrap.sh --playbook preflight --limit <host>
   ```

   Inspect `/etc/qops/preflight.json` on the target.

4. **Full install:**

   ```bash
   ./bootstrap.sh --limit <host>
   ```

   This runs `ansible/playbooks/site.yml`: preflight through kodus, then backup timer installation and `qops-doctor`.

5. **Verify:**

   ```bash
   ./bootstrap.sh --playbook doctor --limit <host>
   ```

   Non-zero exit prints `/etc/qops/doctor.json`. Configure `doctor_webhook_external_probe_cmd` for an off-host curl to `https://kodus-webhooks.<d>/health` if you want webhook reachability verified (skipped when empty).

## After install: Git provider registration

The `kodus` role writes callback URLs to `/etc/qops/kodus/callback-urls.txt` and prints:

| Integration | URL pattern |
|---|---|
| GitHub App callback | `https://kodus.<d>/api/auth/callback/github` |
| GitHub App setup | `https://kodus.<d>/setup/github` |
| GitHub App webhook | `https://kodus-webhooks.<d>/github/webhook` |
| GitHub OAuth callback | `https://kodus.<d>/api/auth/callback/github` |
| MCP OAuth redirect | `https://kodus.<d>/setup/mcp/oauth` |

Register these in the Git provider. Webhooks must use the **dedicated** `kodus-webhooks.<d>` host (not `WEB_HOSTNAME_API`).

## TLS notes

| Mode | M1 support |
|---|---|
| `acme_dns` | Supported — DNS-01 credentials in `/etc/qops/traefik-acme.env` |
| `provided` | Supported — install cert/key paths before `site.yml` |
| `internal_ca` | **Not supported in M1** — role fails explicitly |

## Upgrade

Bump pins only in `versions.yml`, then on the target:

```bash
./bootstrap.sh --playbook upgrade --limit <host>
```

`upgrade.yml` backs up, verifies the bundle, fetches the new E2B dist, asserts API/migration pair match (`bin/api` ldflag, BUILD_INFO, newest migration), sets `FORCE_STOP=true` and creates `/orchestrator/force-stop` before `systemctl stop`, migrates, rebuilds templates only when envd/kernel/Firecracker pins change, upgrades Kodus `IMAGE_TAG`, and runs `qops-doctor`. The E2B seeder is never invoked from upgrade. Live FORCE_STOP is **unverified**.

## What success looks like (unverified on real hosts)

- `doctor.yml` exit 0 with E2B smoke and isolation probe passed
- Worker logs without `falling back to default`
- A test PR receiving a Kodus review comment (requires working LLM, git credentials, and outbound git API access)

CI on GitHub (`installer-matrix.yml`) exercises a subset on `ubuntu-24.04` when repository secrets are configured; see `ci/README.md`.
