# e2b_templates

Builds the `base`, `kodus-sandbox`, and `kodus-sandbox-graph` aliases with
`e2b/templates/build-templates.ts` against `http://127.0.0.1:8080`. TLS is
intentionally off this path.

Kodus references those **aliases**, never build IDs.

## Contract

| Item | Value |
|---|---|
| Script | `/usr/local/lib/qops/e2b-templates` copy of `e2b/templates` |
| API | `E2B_API_URL=http://127.0.0.1:8080` |
| Domain | `E2B_DOMAIN=e2b.<qops_domain>` |
| Key | `E2B_API_KEY` from `/etc/qops/secrets.env` |
| Force | `e2b_templates_force` (`true` on `upgrade.yml`; unset on `site.yml`) |
| Summary | `/var/lib/e2b/templates-last-summary.json` |

Host Node is used when `node -v` matches `versions.yml:node_version`. Otherwise
the role runs a one-shot `node:<node_ci_version>` container (`--network host`)
so `http://127.0.0.1:8080` still works. The image tag is never `latest`.

`site.yml` re-runs leave `E2B_TEMPLATE_FORCE` unset so existing aliases are
`skipped`. The play fails if the JSON summary contains any `action: failed`.

Stale Local-registry `templateId:buildId` images are pruned after a successful
build that produced new `buildId`s.

Implemented in **Task 8** (see `../../../docs/superpowers/specs/2026-08-28-kodus-e2b-selfhost-design.md`, Phase 2).
