# e2b_templates

Builds the `base`, `kodus-sandbox`, and `kodus-sandbox-graph` aliases with
`e2b/templates/build-templates.ts` against `http://127.0.0.1:8080`. TLS is
intentionally off this path.

Kodus references those **aliases**, never build IDs.

## Contract

| Item | Value |
|---|---|
| Controller sources | `e2b_templates_controller_src_dir` (`playbook_dir`/../../e2b/templates) |
| Host staging | `e2b_templates_src_dir` (`/var/cache/qops/e2b-templates-src`) after an Ansible `copy` |
| Script | `/usr/local/lib/qops/e2b-templates` copy of the host staging tree |
| API | `E2B_API_URL=http://127.0.0.1:8080` |
| Domain | `E2B_DOMAIN=e2b.<qops_domain>` |
| Key | `E2B_API_KEY` from `/etc/qops/secrets.env` |
| Force | `e2b_templates_force` (`true` on `upgrade.yml`; unset on `site.yml`) |
| Summary | `/var/lib/e2b/templates-last-summary.json` |

Host Node is used when `node -v` matches `versions.yml:node_version`. Otherwise
the role runs a one-shot `node:<node_ci_version>` container (`--network host`)
so `http://127.0.0.1:8080` still works. The image tag is never `latest`.

`site.yml` re-runs leave `E2B_TEMPLATE_FORCE` unset so existing aliases are
`skipped`. `upgrade.yml` sets `e2b_templates_force=true` **only when**
`envd_version` (BUILD_INFO), `firecracker_version`, or `kernel_version` changed
relative to the installed cluster. The play fails if the JSON summary contains
any `action: failed`.

The controller copies `e2b/templates` onto the managed host first
(`ansible.builtin.copy` from `e2b_templates_controller_src_dir` to
`e2b_templates_src_dir`). Host-side `install-template-sources.sh` /
`build-templates.ts` never read a `playbook_dir` path.

Stale Local-registry `templateId:buildId` images are pruned after a successful
build that produced new `buildId`s. The pruner retains `templateId:buildId`
from the JSON summary (aliases are not Docker repositories) and fails the
play if a requested `docker rmi` fails.

Implemented in **Task 8** (see `../../../docs/superpowers/specs/2026-08-28-kodus-e2b-selfhost-design.md`, Phase 2).
