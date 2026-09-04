# Documentation

Operator and developer documentation for codereviewer.

| Document | Task |
|---|---|
| `install.md` | Task 13 |
| `operations.md` | Task 13 / M2 |
| `security.md` | Task 13 |
| `spike-notes.md` | Phase 0 (manual) |
| `distro-notes/` | M1/M2 per-distro matrix legs |

Authoritative design spec: `superpowers/specs/2026-08-28-kodus-e2b-selfhost-design.md`.

**Version pinning exception:** `min_ansible_version` in each role's `meta/main.yml` is a Galaxy compatibility floor (`2.16`, tested on Ansible 2.21.x in dev/CI), not an artifact pin — all deployable version pins live in `versions.yml`.

**`.gitkeep` convention:** only in directories with no other tracked file; directories that already contain a `README.md` (e.g. `ci/`, `e2b/build/`) do not need one.
