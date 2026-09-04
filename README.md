# codereviewer

Repeatable Ansible installer for **[Kodus](https://kodus.io)** (AI code review, self-hosted via `kodustech/kodus-installer`) plus a **self-hosted single-node [E2B](https://github.com/e2b-dev/infra)** Firecracker sandbox cluster on customer-owned **x86_64 Linux** hosts. No GCP/AWS dependency.

## Architecture

Traefik (systemd, the **only** service binding `0.0.0.0:80/443`) terminates TLS and routes `kodus.*`, `api.e2b.*`, and `*.e2b.*` hostnames. Kodus runs in Docker Compose; E2B orchestrator, API, and client-proxy run as host processes with bundled Postgres/Redis/ClickHouse/OTel in Docker on `127.0.0.1`. Sandboxes are Firecracker microVMs on the same node.

See the [design spec](docs/superpowers/specs/2026-08-28-kodus-e2b-selfhost-design.md) for the full topology.

## What works today (M1 skeleton)

| Verified on this machine | Not yet implemented |
|---|---|
| `make check` (yamllint, ansible-lint, shellcheck, syntax-check, bats) | Role tasks (all placeholders) |
| `./bootstrap.sh --syntax-check` / `--check` wiring to Ansible | Actual install against a target host |
| Inventory-overridable defaults from `group_vars/all.yml` | E2B build pipeline, templates, Traefik, Kodus |
| Stubbed `bootstrap.sh` flag forwarding and pipx install-path tests | Container-based bootstrap install test (written, **skipped** when Docker absent) |

**Roles are placeholders** — `./bootstrap.sh` (without `--syntax-check`) would invoke Ansible but perform no real provisioning until Tasks 5–11 land.

## Quickstart

From a clean checkout on an x86_64 Linux control host:

```bash
# Validate playbook wiring (no target host, no provisioning)
./bootstrap.sh --syntax-check

# After configuring ansible/inventory/example.yml and implementing roles:
# ./bootstrap.sh
```

`bootstrap.sh` can install Ansible via `pipx` when missing (see `tests/bats/bootstrap-install-path.bats`). For lab SSH without host-key prompts: `export ANSIBLE_HOST_KEY_CHECKING=False`.

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

All image tags, git refs, and binary versions live in **`versions.yml`**. Nothing else in the repo may hard-code versions. `kodus_image_tag` is never `latest`. E2B upstream changes go only through `e2b/patches/`. `e2b/e2b.pin` mirrors `e2b_pin` for the build container; `tests/bats/versions.bats` keeps them aligned.

## Development

```bash
make check    # lint + bats
make lint     # yamllint, ansible-lint, shellcheck, syntax-check
make test     # bats only
```

## Documentation

- [Design spec](docs/superpowers/specs/2026-08-28-kodus-e2b-selfhost-design.md)
- [docs/](docs/README.md) — install/operations guides (coming in Task 13)
