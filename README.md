# codereviewer

Repeatable Ansible installer for **[Kodus](https://kodus.io)** (AI code review, self-hosted via `kodustech/kodus-installer`) plus a **self-hosted single-node [E2B](https://github.com/e2b-dev/infra)** Firecracker sandbox cluster on customer-owned **x86_64 Linux** hosts. No GCP/AWS dependency.

## Architecture

Traefik (systemd, the **only** service binding `0.0.0.0:80/443`) terminates TLS and routes `kodus.*`, `api.e2b.*`, and `*.e2b.*` hostnames. Kodus runs in Docker Compose; E2B orchestrator, API, and client-proxy run as host processes with bundled Postgres/Redis/ClickHouse/OTel in Docker on `127.0.0.1`. Sandboxes are Firecracker microVMs on the same node.

See [docs/architecture.md](docs/architecture.md) and the [design spec](docs/superpowers/specs/2026-08-28-kodus-e2b-selfhost-design.md).

## Status (M1)

| Area | State |
|---|---|
| Ansible roles (12) + playbooks | Implemented — see `ansible/roles/*/README.md` |
| E2B build pipeline + templates | Implemented — `e2b/build/`, `e2b/templates/` |
| CI: lint, build-e2b, pin-bump | Workflow YAML present; **GitHub execution not verified in this environment** |
| CI: installer matrix (Ubuntu 24.04) | `.github/workflows/installer-matrix.yml` — requires repo secrets + KVM runner |
| Phase 0 feasibility spike | **Not executed** — gate checklist in [docs/spike-notes.md](docs/spike-notes.md) |
| Customer / lab install | **Never run on a real host** |

Local verification (no Docker/KVM here): `make check`, `actionlint`, `yamllint .`, bats.

## Quickstart

```bash
# Validate playbook wiring (no target host, no provisioning)
./bootstrap.sh --syntax-check

# After configuring ansible/inventory/example.yml and group_vars:
# ./bootstrap.sh --limit <host>
```

See [docs/install.md](docs/install.md) for operator steps.

## Repository layout

```
versions.yml          # sole source of version pins
bootstrap.sh          # entry point
ansible/              # playbooks, roles, inventory, group_vars
e2b/                  # pin, patches, build pipeline, templates
ci/                   # GitHub Actions helpers + matrix scripts
docs/                 # architecture, install, operations, security
tests/                # bats + fixtures
```

## Pinning policy

All image tags, git refs, and binary versions live in **`versions.yml`**. `kodus_image_tag` is never `latest`. E2B upstream changes go only through `e2b/patches/`. `e2b/e2b.pin` mirrors `e2b_pin`; bats keeps them aligned.

## Development

```bash
make check    # lint + bats + docs-accuracy
make lint     # yamllint, ansible-lint, shellcheck, syntax-check
make test     # bats only
```

## Documentation

| Doc | Audience |
|---|---|
| [install.md](docs/install.md) | Customer operator |
| [operations.md](docs/operations.md) | Runbooks |
| [security.md](docs/security.md) | Threat model and bind policy |
| [spike-notes.md](docs/spike-notes.md) | Phase 0 gate (unchecked) |
| [distro-notes/ubuntu-24.04.md](docs/distro-notes/ubuntu-24.04.md) | M1 distro support |
| [ci/README.md](ci/README.md) | CI workflows |
| [Design spec](docs/superpowers/specs/2026-08-28-kodus-e2b-selfhost-design.md) | Full plan |
