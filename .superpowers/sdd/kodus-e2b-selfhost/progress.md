# Subagent-driven development ledger — Kodus + self-hosted E2B installer (M1)

Spec: [docs/superpowers/specs/2026-08-28-kodus-e2b-selfhost-design.md](../../../docs/superpowers/specs/2026-08-28-kodus-e2b-selfhost-design.md)

## Model assignment

| Role | Model |
|---|---|
| Implementer (correctness-critical) | `cursor-grok-4.6-high-fast` |
| Implementer (scaffolding / volume) | `composer-2.5` |
| Task reviewer | `gpt-5.6-sol-high` |
| Final whole-branch reviewer | `gpt-5.6-sol-xhigh` |

One fresh implementer per task, never two in parallel, no sub-subagents. Fix loop: rounds 1-3
resume the same implementer, rounds 4-5 escalate to a fresh Grok 4.6 implementer, round 5 is the
breaker and the controller adjudicates.

## Global constraints (handed verbatim to every reviewer)

1. Pins come only from `versions.yml`; no version literals anywhere else.
2. Bind policy: only Traefik listens on `0.0.0.0` (80/443). Everything else binds `127.0.0.1` or is
   dropped by the host nftables input chain.
3. No Kodus fork. Changes are limited to `.env` values and `docker-compose.override.yml`.
4. E2B source changes only via `e2b/patches/`.
5. `IMAGE_TAG` is never `latest`.
6. The E2B seeder is gated on a database query, never on a file marker.
7. Kodus references template **aliases** (`kodus-sandbox`, `kodus-sandbox-graph`), never build IDs.
8. The orchestrator systemd unit carries no sandboxing directives.
9. Every role is idempotent: a second `site.yml` run reports zero changes and triggers no template build.
10. Anything not demonstrated by a run command is marked unverified. Reviewers flag claimed-but-untested work.

## Upstream ground truth verified before implementation

- E2B pin `6e4ce14cdd12c4d6bca1ecf795840b3b9afba0a2` (2026-08-28, "chore(main): release api 0.7.0"),
  Go toolchain `1.26.6` from `go.work`.
- Every Kodus compose service including `worker` carries `env_file: - .env`, and the E2B SDK resolves
  `domain` as `opts.domain -> E2B_DOMAIN -> "e2b.app"`. The config-only redirect is structurally sound.
- `kodus-installer/scripts/install.sh` runs `docker compose up -d --force-recreate` unconditionally,
  so the `kodus` role must gate the invocation on stack health to stay idempotent.
- `scripts/generate-secrets.sh` overwrites secrets on re-run: run once, persist under `/etc/qops`.
- Bitbucket and Azure webhook variables are `GLOBAL_`-prefixed, not `API_`-prefixed.
- `packages/shared/pkg/featureflags` exposes `OverrideBoolFlag`/`OverrideJSONFlag` but no
  `OverrideIntFlag`, so an env override for `max-starting-instances-per-node` needs a new code path.
- `packages/api/Makefile` embeds `-X=main.expectedMigrationTimestamp=$(expectedMigration)` derived
  from `ls ../db/migrations`.

## PR / branch map

| PR | Branch | Tasks | Status |
|---|---|---|---|
| 1 | `cursor/foundation-skeleton-2bb0` | 1 | merged to stack; https://github.com/qopsc/gremlintrace/pull/1 |
| 2 | `cursor/e2b-build-pipeline-2bb0` | 2, 3, 4 | merged to stack; https://github.com/qopsc/gremlintrace/pull/2 |
| 3 | `cursor/ansible-host-base-roles-2bb0` | 5, 6 | merged to stack; https://github.com/qopsc/gremlintrace/pull/3 |
| 4 | `cursor/ansible-e2b-services-traefik-2bb0` | 7, 8 | merged to stack; https://github.com/qopsc/gremlintrace/pull/4 |
| 5 | `cursor/ansible-kodus-doctor-2bb0` | 9, 10 | merged to stack; https://github.com/qopsc/gremlintrace/pull/5 |
| 6 | `cursor/operations-ci-docs-2bb0` | 11, 12, 13 | merged to stack; https://github.com/qopsc/gremlintrace/pull/6 |

Final whole-branch review (`gpt-5.6-sol-xhigh`): APPROVE. `make check` green: 203 bats, 29 vitest, ansible-lint production, actionlint.

Phase 0 spike, live host install, live FORCE_STOP marker observation, live GC against Postgres, and the GitHub Actions matrix run remain **unverified**.

## Task ledger

All 13 M1 tasks implemented, reviewed, and stacked. See the six PRs.
