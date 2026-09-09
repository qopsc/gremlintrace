# Documentation

Operator and developer documentation for codereviewer.

| Document | Audience |
|---|---|
| [architecture.md](architecture.md) | Topology, bind policy, request path |
| [install.md](install.md) | Customer install procedure |
| [operations.md](operations.md) | Failure-mode runbooks, backup, GC, upgrade |
| [security.md](security.md) | Root services, secrets, threat model |
| [spike-notes.md](spike-notes.md) | Phase 0 gate checklist (**unchecked**) |
| [distro-notes/ubuntu-24.04.md](distro-notes/ubuntu-24.04.md) | M1 Ubuntu support |

Authoritative design spec: [superpowers/specs/2026-08-28-kodus-e2b-selfhost-design.md](superpowers/specs/2026-08-28-kodus-e2b-selfhost-design.md).

**Honesty bar:** This repository has **not** been installed on a real customer host. Docs describe intended behaviour from role READMEs and the spec; Phase 0 and production validation remain open.

**Version pinning exception:** `min_ansible_version` in each role's `meta/main.yml` is a Galaxy compatibility floor (`2.16`, tested on Ansible 2.21.x in dev/CI), not an artifact pin — all deployable version pins live in `versions.yml`.
