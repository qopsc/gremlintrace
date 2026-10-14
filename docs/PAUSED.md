# Paused and outstanding work

Last updated: 2026-10-14, after `fix/m1-audit-remediation` (37 commits) was merged and
pushed; `origin/main` = `8799905`. This file is the single list of what is paused, what
is owed, and what is still to do. It replaces session memory and the deleted SDD ledger;
the audit record for the remediation is [audits/2026-09-09-pr9-review.md](audits/2026-09-09-pr9-review.md).

How to read an entry: `**P-nn** [STATUS] what — where — why it is open — done when — proof`.

| Status | Meaning |
|---|---|
| PAUSED | Decided or started, deliberately not finished |
| TODO | Not started |
| PROVE | Code is done; behaviour is unverified on a real host or a real CI run |
| DECIDE | Needs the owner's call before work can start |

Proof levels: `bats` (local/CI unit tests), `matrix` (the `installer-matrix` workflow on a
GitHub runner), `lab` (a KVM-capable host with real DNS and a public IP).

## 1. Blockers

- **P-01** [PROVE] Phase 0 has never been executed — `docs/spike-notes.md:3` ("no
  KVM-capable lab host"); all nine gates unchecked (`spike-notes.md:5-15`, `:30-38`), seven
  assumptions unverified (`:42-88`: `ENVIRONMENT=prod`, `SHARED_CHUNK_CACHE_PATH`, pgcrypto,
  `max-starting-instances-per-node=3`, snapshot layout and header-chain GC data-loss risk,
  hairpin NAT, nested-virt performance), sign-off blank (`:127-132`) — done when a lab run
  ticks every gate and `ci/check-docs-accuracy.py:97-101`, which currently fails if the
  boxes are ticked, is updated in the same change — proof: lab.
- **P-02** [PROVE] No workflow has ever run on GitHub Actions — `ci/README.md:6`; the
  "what remains untested" list at `ci/README.md:252-262` (real Docker build, validator
  against a real dist, artifact passing between jobs, Release layout, pin-bump PR creation,
  lint on a runner, cron, first `installer-matrix` run, webhook-to-review end to end) — done
  when each workflow has one green run from `main` — proof: matrix.
- **P-03** [TODO] The `installer-matrix` leg needs repository secrets `QOPS_CI_LLM_API_KEY`,
  `QOPS_CI_CANARY_REPO_TOKEN`, `QOPS_CI_WEBHOOK_EXTERNAL_PROBE_CMD` and the variable
  `QOPS_CI_CANARY_REPO`; when any is missing, or the PR is from a fork, the leg prints
  `skip:` and still reports success (`ci/matrix/gate-secrets.sh:15-29`) — a green badge
  proves nothing until the secrets exist — done when the secrets are set and one dispatched
  run shows `run_install=true` — proof: matrix.

## 2. Paused: decided or started, not finished

- **P-04** [DECIDE] `origin/automation/bump-e2b-pin` (`9d63993`, 2026-10-01, "Bump e2b_pin
  to latest upstream infra") is an unmerged automated bump of `versions.yml` and `e2b.pin` —
  merge after a `build-e2b` run, rebase onto `main`, or close it; the monthly cron will keep
  opening these.
- **P-05** [PAUSED] `ansible/playbooks/restore.yml:14-16` and `backup.yml:14-16` are debug
  stubs ("implemented in M2"); `docs/operations.md:188` records "No rollback in M1" and the
  manual restore at `:205` is unverified end to end; the RabbitMQ import at `:94-96`
  likewise; `ci/README.md:18` restore-drill workflow "M2 — not yet in repo" — done when
  `restore.yml` restores a bundle produced by `qops-backup` and a drill workflow proves it —
  proof: matrix, then lab.
- **P-06** [PAUSED] Reviewer minor #6: the hairpin probe mounts the CA only for
  `tls_mode: internal_ca` (`ansible/roles/traefik/tasks/hairpin.yml`), so `provided` with a
  private CA still fails the required gate with a misleading hint; and a non-required re-run
  burns the full 30-attempt budget before printing `skipped`
  (`ansible/roles/traefik/files/hairpin-check.sh`) — done when `tls_ca_path` is passed
  whenever set and `TRAEFIK_HAIRPIN_REQUIRED=0` uses a short retry budget — proof: bats.
- **P-07** [PAUSED] Reviewer minor #8: `TimeoutStopSec=2160` in
  `ansible/roles/e2b_services/templates/e2b-orchestrator.service.j2` also governs reboot and
  shutdown, so an unattended-upgrades reboot with live sandboxes can hang about 36 minutes
  — done when `docs/operations.md` says so next to the drain runbook — proof: docs review.
- **P-08** [PAUSED] Reviewer minor #9: `bootstrap.sh` uses `dirname "$INVENTORY"` to find
  `host_vars`, which is wrong for a directory inventory; and nothing stops an unencrypted
  `*.sops.yml` from being committed — done when bootstrap handles both inventory shapes and
  a `ci/check-*` script asserts every `*.sops.yml` has a `sops:` block and `ENC[` values —
  proof: bats.
- **P-09** [PAUSED] Reviewer minor #10: the manual mongorestore command in
  `docs/operations.md` puts the password on argv — done when it mirrors the backup's
  `--config` file approach in `ansible/roles/backup/files/qops-backup` — proof: docs review.
- **P-10** [PAUSED] F2, deferred by the owner: `ci/matrix/wildcard-dns.py:81-82` returns no
  answer for in-zone queries whose type is not A/ANY, so the serve loop (`:135`) forwards them (AAAA from `getent ahosts`) upstream, which answers
  NXDOMAIN; systemd-resolved caches that per name, so a following A lookup can fail
  (`audits/2026-09-09-pr9-review.md`, "Known open after the fix") — done when in-zone
  non-A types get NOERROR with an empty answer section and only out-of-zone names are
  forwarded — proof: bats, then matrix. Track before the matrix leg is relied on.
- **P-11** [DECIDE] `.superpowers/sdd/kodus-e2b-selfhost/progress.md` is tracked in git;
  its line 60 still correctly lists Phase 0, live install, live FORCE_STOP, live GC and the
  Actions matrix as unverified — decide whether a tool ledger stays in the repo or this file
  supersedes it.
- **P-12** [DECIDE] The design spec expects an M2 plan document "after M1's final review"
  (`docs/superpowers/specs/2026-08-28-kodus-e2b-selfhost-design.md:449`); none exists.
  Section 8 below is the raw material.

## 3. Proof owed on a real host or a real CI run

Code exists and is covered by bats; the behaviour has not been observed where it matters.

- **P-13** [PROVE] Drain budget: the orchestrator unit's `TimeoutStopSec=2160` and the
  README's "about 35 minutes" rest on the upstream figure, not a measurement
  (`ansible/roles/e2b_services/README.md:60-62`, `docs/operations.md:32`,
  `e2b/patches/README.md:30` live force-stop marker) — proof: lab, with live sandboxes.
- **P-14** [PROVE] Hosts reached through ProxyJump or a non-default sshd port must set
  `host_firewall_ssh_ports` (`ansible/roles/host_firewall/README.md`); the default derives
  from `ansible_port` only. Cost if ignored: SSH lockout at the end of play one — proof: lab
  on such a host.
- **P-15** [PROVE] `bootstrap.sh` returns early when a system `ansible-playbook` exists and
  does not check its version against `versions.yml`; only the pipx path is pinned — done
  when the early return also enforces the pin — proof: bats.
- **P-16** [PROVE] A config change during `site.yml` restarts the orchestrator through an
  ordinary stop (drain), not the force-stop path `upgrade.yml` uses; documented in
  `ansible/roles/e2b_services/README.md:62` rather than changed — proof: lab.
- **P-17** [PROVE] `site.yml --check` is supported only through the preflight dry run;
  later templating fails because the controller tempfile and pack steps are skipped — proof:
  matrix (`check-idempotency.sh` covers re-runs, not `--check`).
- **P-18** [PROVE] Items the matrix cannot reach (`ci/README.md:203-221`): real GitHub
  webhook delivery, a canary review, graph-stage output, a 700 s `commands.run`, reboot,
  upgrade from the previous pin, ten parallel reviews, the 26.04 and Fedora legs. The reboot
  gate always reports skip (`.github/workflows/installer-matrix.yml:212-221`,
  `ci/matrix/check-reboot-skip.sh:5-7`) until a self-hosted M2 leg exists; the escape hatch
  `QOPS_CI_ORCHESTRATOR_RESTART_SKIP_UNVERIFIED=1`
  (`ci/matrix/check-orchestrator-restart.sh:9-11`) must stay unset in CI.
- **P-19** [PROVE] The ACME DNS-01 path with SOPS-provided credentials
  (`ansible/roles/traefik/files/install-traefik-acme-env.sh`) and the hairpin gate
  (`hairpin-check.sh`) run only under `tls_mode: provided` in CI — proof: lab with a real
  zone and a public IP.
- **P-20** [PROVE] Documented as unverified on a live host and still so:
  `docs/operations.md:3`, `:28` (start throttle), `:55` (hugepage re-run determinism, also
  `ansible/roles/e2b_host/README.md:25`), `:240` (GC header-chain walk; also
  `ansible/roles/backup/README.md:61-62`); `e2b/build/README.md:123-133` (Docker build, Go
  compile, linkage check, clone and patch apply); `e2b/templates/README.md:164-176`
  (`Template.build` against a real API, base image pull, `E2B_TEMPLATE_FORCE`, private
  registry, Kodus using the aliases); `docs/distro-notes/ubuntu-24.04.md:7`, `:47`, `:49-53`
  "Implemented (unverified)"; `ansible/roles/doctor/files/qops-doctor:470` webhook
  reachability without an external probe — proof: matrix for the build and template items,
  lab for the rest.
- **P-21** [PROVE] Local bats skip when a tool is missing, so a local green run is not full
  coverage: `nft` (`tests/bats/ansible-roles.bats:130`), `systemd-analyze`
  (`tests/bats/backup.bats:208`, `tests/bats/e2b-services-traefik.bats:90`), Docker
  (`tests/bats/bootstrap-install.bats:10`, `:13`), sops and age
  (`tests/bats/group_vars.bats:80`) — done when the lint workflow's first real run shows
  zero skips — proof: matrix.

## 4. Spec and process gaps

- **P-22** [TODO] No CI assertion that Kodus posts a review on a canary PR (spec acceptance;
  `audits/2026-09-09-pr9-review.md` "P2 acceptance gap"; spec verification chain
  `docs/superpowers/specs/2026-08-28-kodus-e2b-selfhost-design.md:457-460` also wants the
  700 s run, reboot, and upgrade from the previous pin) — proof: matrix with
  `QOPS_CI_CANARY_REPO`.
- **P-23** [TODO] Linkage validation is duplicated: `assert_static` and `assert_dynamic` in
  `e2b/build/build.sh:322,336` and `ci/validate-e2b-dist.sh:32,43` — done when one helper is
  sourced by both — proof: bats.
- **P-24** [TODO] PRs #10, #11 and #12 (Ansible host, datastore, services and operations
  roles; tests and fixtures) never received an external review; CodeRabbit skipped them
  (`audits/2026-09-09-pr9-review.md:13-17`). The remediation branch had one model review
  plus the author's fix pass — done when a second reviewer reads the roles on `main`.
- **P-25** [TODO] Of the PR #9 CodeRabbit comments, 15 minor and 3 nitpick items were not
  all reproduced or promoted (local, git-ignored `.scratch/pr-9-review/review.md`) — decide
  per item or drop with a note in the audit record.
- **P-26** [TODO] Operational gaps the docs admit: Cloudflare Tunnel / NAT path not wired
  in CI (`docs/operations.md:123`); API key rotation not automated (`:171-172`,
  `docs/security.md:83-86`); prompt-injection review incomplete (`security.md:83-86`); remote
  access out of scope (`security.md:79`); threat-model validation not executed
  (`security.md:3`).

## 5. Operator setup not yet done

An install cannot start until an operator completes these; none are code defects.

- **P-27** [TODO] `.sops.yaml:12` holds the placeholder age recipient
  `age1replace0with0your0operator0recipient…`; replace with the real public key and keep the
  private key in `SOPS_AGE_KEY_FILE` on the controller only (`.sops.yaml:8`,
  `docs/security.md:61`).
- **P-28** [TODO] Create `ansible/inventory/host_vars/<host>/secrets.sops.yml` from
  `ansible/inventory/host_vars/example-host/secrets.sops.yml.example:10-14` (replace
  `pk1_replace`, `sk1_replace`, `sk-replace`) and encrypt it with `sops`; the traefik and
  kodus roles now refuse values that still read `ENC[`.
- **P-29** [TODO] `ansible/inventory/example.yml:11` is `hosts: {}` with commented samples;
  a real inventory is needed before `bootstrap.sh`.
- **P-30** [TODO] Set the three CI secrets and the canary variable from P-03 in the GitHub
  repository settings; until then `installer-matrix` skips.

## 6. Doc drift to fix

- **P-31** [TODO] `docs/operations.md:32` still says "SIGKILL at `TimeoutStopSec=180`"; the
  unit now sets 2160 (`ansible/roles/e2b_services/templates/e2b-orchestrator.service.j2`).
  Fold into P-07.
- **P-32** [TODO] `docs/security.md:75` lists two CI secrets and omits
  `QOPS_CI_WEBHOOK_EXTERNAL_PROBE_CMD`, which `ci/matrix/gate-secrets.sh` requires.
- **P-33** [TODO] `docs/distro-notes/README.md:8-11` links `ubuntu-26.04.md` and
  `fedora-44.md`, which do not exist (M2 legs); either add stubs that say so or drop the
  links.
- **P-34** [TODO] `docs/install.md:114` "What success looks like (unverified)" and
  `docs/README.md` "Honesty bar" stay as written until P-01 and P-02 close; then both need
  rewording in the same change.

## 7. Environment hazards on the development machine

- **P-35** [DECIDE] Something on the controller creates Finder-style " 2" duplicates inside
  `~/Documents/qops/git/gremlintrace` (155 byte-identical copies such as
  `ansible/roles/common/templates/secrets.env 2.j2` appeared between two test runs on
  2026-10-11 and broke the template-render bats; a stray
  `.git/refs/heads/fix/m1-audit-remediation 2` also broke `git fetch`). The copies were
  removed; three inert ones remain in `.git` (`ORIG_HEAD 2`, `index 2`,
  `objects/maintenance 2.lock`). Find the sync or backup tool responsible (the repo lives
  under `Documents`) or move the checkout out of its reach; until then expect flaky bats and
  broken fetches.

## 8. M2 backlog as the repo records it

Not M1 work; listed so nothing is lost when the M2 plan (P-12) is written.

- **P-36** `tls_mode: internal_ca` (`ansible/roles/traefik/README.md:41`,
  `ansible/roles/traefik/files/check-tls-mode.sh:12` fails explicitly; `docs/install.md:17`,
  `:102`; `docs/architecture.md:105-106`).
- **P-37** S3 / NFS storage backends (`ansible/roles/e2b_services/tasks/main.yml:5-6`,
  `ansible/playbooks/upgrade.yml:35`, `ansible/group_vars/all.yml:114`).
- **P-38** Backup coverage: template store, ClickHouse and Redis dumps, off-box
  `backup_target: s3|rsync`, weekly restore drill (`ansible/roles/backup/README.md:41-46`,
  `docs/operations.md:194`, `:203`).
- **P-39** Fedora 44 and Ubuntu 26.04 legs (`ansible/roles/common/tasks/main.yml:8`,
  `docs/distro-notes/README.md:8-11`); a self-hosted runner for the reboot gate (P-18).
- **P-40** Multi-node topology (`docs/architecture.md:105-106`); Loki
  (`docs/superpowers/specs/2026-08-28-kodus-e2b-selfhost-design.md:382`); the rest of the
  M2 scope and the beyond-v1 list (spec `:392`, `:394-395`).
- **P-41** Patch candidate: env-overridable `max-starting-instances-per-node`, pending the
  Phase 0 throttle measurement (`e2b/patches/README.md:32-43`, `docs/operations.md:28`).
