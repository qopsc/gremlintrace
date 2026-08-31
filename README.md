# codereviewer

Repeatable Ansible installer for **[Kodus](https://kodus.io)** (AI code review, self-hosted via `kodustech/kodus-installer`) plus a **self-hosted single-node [E2B](https://github.com/e2b-dev/infra)** Firecracker sandbox cluster on customer-owned **x86_64 Linux** hosts. No GCP/AWS dependency.

## Architecture

Traefik (systemd, the **only** service binding `0.0.0.0:80/443`) terminates TLS and routes `kodus.*`, `api.e2b.*`, and `*.e2b.*` hostnames. Kodus runs in Docker Compose; E2B orchestrator, API, and client-proxy run as host processes with bundled Postgres/Redis/ClickHouse/OTel in Docker on `127.0.0.1`. Sandboxes are Firecracker microVMs on the same node.

See the [design spec](docs/superpowers/specs/2026-08-28-kodus-e2b-selfhost-design.md) for the full topology.

## Quickstart

From a clean checkout on an x86_64 Linux control host:

```bash
# Validate playbooks (no target host required)
./bootstrap.sh --syntax-check

# Full install (after configuring ansible/inventory/example.yml)
./bootstrap.sh
```

`bootstrap.sh` installs Ansible via `pipx` when missing, then runs `ansible/playbooks/site.yml`.

## Repository layout

```
versions.yml          # sole source of version pins
bootstrap.sh          # entry point
ansible/              # playbooks, roles, inventory, group_vars
e2b/                  # pin, patches, build pipeline, templates
ci/                   # GitHub Actions (added in later tasks)
docs/                 # operator docs + design spec
tests/                # bats + fixtures
```

## Pinning policy

All image tags, git refs, and binary versions live in **`versions.yml`**. Nothing else in the repo may hard-code versions. `kodus_image_tag` is never `latest`. E2B upstream changes go only through `e2b/patches/`.

## Development

```bash
make check    # lint + bats
make lint     # yamllint, ansible-lint, shellcheck, syntax-check
make test     # bats only
```

## Status

This repository is under active development (Milestone 1). Roles are placeholders until their implementing tasks land; only syntax-check and unit tests have been run in CI-less dev environments.

## Documentation

- [Design spec](docs/superpowers/specs/2026-08-28-kodus-e2b-selfhost-design.md)
- [docs/](docs/README.md) — install/operations guides (coming in Task 13)
