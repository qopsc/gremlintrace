# CI workflows

GitHub Actions workflows for building the E2B dist tarball, bumping the upstream
pin, and linting the repository on every pull request.

**None of these workflows have ever executed on GitHub Actions.** This
environment has no Docker daemon and no KVM; local verification is limited to
`actionlint`, `yamllint`, `make check`, and the bats suite (including workflow
policy tests). The real E2B Docker build, artifact mirroring in CI, and release
upload are untested here.

| Workflow | File | Task |
|---|---|---|
| Build E2B dist | `.github/workflows/build-e2b.yml` | Task 3 |
| Bump E2B pin | `.github/workflows/pin-bump.yml` | Task 3 |
| Lint | `.github/workflows/lint.yml` | Task 3 |
| Installer matrix | `.github/workflows/installer-matrix.yml` | Task 12 |
| Restore drill | _(M2 — not yet in repo)_ | M2 |

## `build-e2b.yml`

### Triggers

- `workflow_dispatch` — operator-initiated dist build **and** GitHub Release publish
  when run from `main`.
- `push` / `pull_request` — only when `versions.yml`, `e2b/**`, or this workflow
  changes. Builds and validates; **does not** publish a release on PRs or ordinary
  pushes (avoids accidental releases on every merge).

Release publishing is limited to `workflow_dispatch` so cutting a dist is an
explicit operator action after review, not a side effect of merging.

### What it does

1. **`versions` job** — reads every key from `versions.yml` via `ci/yaml_versions.py`
   (stdlib-only parser) and exposes them as job outputs. No version literals appear
   in the workflow file.
2. **`build-dist` job** — runs `e2b/build/build.sh` (Docker build of the pinned
   upstream tree + patches), then `ci/validate-e2b-dist.sh` on the tarball:
   - `sha256sum -c SHA256SUMS` after extraction
   - every expected `bin/*` present and executable
   - `BUILD_INFO.e2b_pin` equals `versions.yml:e2b_pin`
   - `BUILD_INFO.expected_migration_timestamp`, the newest
     `migrations/postgres/` filename prefix, **and** the value embedded in `bin/api`
     (`expectedMigrationTimestamp` ldflag) all agree — the API refuses to start when
     any of these disagree with the shipped migrations
   - `envd` and `api` statically linked; `orchestrator` dynamically linked
3. **`mirror-artifacts` job** (parallel) — `ci/mirror-e2b-artifacts.sh` downloads
   Firecracker, kernel, and busybox from `https://storage.googleapis.com/e2b-artifact-binaries/`
   into the layout upstream `fc/config.go` expects (`<kind>/<ver>/amd64/<file>`),
   verifies all three binaries against the SHA-256 pins in `versions.yml` and busybox
   against the published `.sha256`, writes `artifacts-SHA256SUMS`,
   then `ci/pack-mirrored-artifacts.sh` packs the tree into a single release tarball
   (plain `files:` upload would flatten paths). Fails on HTTP non-200 and removes
   only its temporary staging tree on any error, preserving pre-existing output
   contents.
4. **`publish-release` job** (`workflow_dispatch` on `main` only) —
   `ci/stage-release.sh` uploads the dist tarball and checksum plus the packed FC
   tarball and checksum to a new, immutable GitHub Release tagged
   `e2b-<e2b_dist_version>`.

### Release asset layout

Ansible (later tasks) downloads assets from the release tagged
`e2b-<e2b_dist_version>` (for example `e2b-6e4ce14`):

| Release asset | Purpose |
|---|---|
| `e2b-<e2b_dist_version>.tar.gz` | Built dist: `bin/*`, migrations, `otel-collector.yaml`, `BUILD_INFO`, `SHA256SUMS` |
| `e2b-<e2b_dist_version>.tar.gz.sha256` | SHA-256 checksum of the dist tarball |
| `e2b-fc-artifacts-<e2b_dist_version>.tar.gz` | Mirrored Firecracker/kernel/busybox tree (hierarchy preserved) |
| `e2b-fc-artifacts-<e2b_dist_version>.tar.gz.sha256` | SHA-256 checksum of the FC artifacts tarball |

Extract the FC artifacts tarball to obtain the host layout expected by
`fc/config.go` (paths relative to the extraction directory):

```bash
mkdir -p /tmp/fc-artifacts
tar -xzf e2b-fc-artifacts-<e2b_dist_version>.tar.gz -C /tmp/fc-artifacts
cd /tmp/fc-artifacts && sha256sum -c SHA256SUMS
# firecrackers/<firecracker_version>/amd64/firecracker
# kernels/<kernel_version>/amd64/vmlinux.bin
# busybox/<busybox_version>/amd64/busybox
```

`<firecracker_version>`, `<kernel_version>`, and `<busybox_version>` come from
`versions.yml` at build time.

### Permissions and secrets

| Job | `permissions` | Secrets |
|---|---|---|
| `versions`, `build-dist`, `mirror-artifacts` | `contents: read` (workflow default) | none |
| `publish-release` | `contents: write` | `GITHUB_TOKEN` (default) |

No repository secrets are required.

## `pin-bump.yml`

### Triggers

- `schedule` — `0 6 1 * *` (06:00 UTC on the 1st of each month)
- `workflow_dispatch`

### What it does

1. `ci/bump-e2b-pin.sh` resolves `e2b-dev/infra` `HEAD` via `git ls-remote`.
2. If it differs from `versions.yml:e2b_pin`, updates `versions.yml`
   (`e2b_pin`, `e2b_dist_version`, `e2b_go_version` from upstream `go.work`,
   `envd_version`, `goose_version`, Firecracker/kernel/busybox versions, and
   their SHA-256 pins) and syncs `e2b/e2b.pin`. When the upstream pin is already
   current, it still verifies the three committed artifact hashes.
3. Opens a pull request via `peter-evans/create-pull-request` on branch
   `automation/bump-e2b-pin`. The workflow then explicitly dispatches the E2B
   build and lint workflows for that branch (and an installer matrix when present),
   because a PR created with `GITHUB_TOKEN` does not start pull-request workflows.
   It does **not** push to the default branch and does **not** auto-merge.

A dist bump that changes envd, kernel, or Firecracker pins requires E2B template
rebuilds; `upgrade.yml` (a later task) handles that via `env_builds.envd_version`.

### Permissions and secrets

| Job | `permissions` | Secrets |
|---|---|---|
| `bump-pin` | `actions: write`, `contents: write`, `pull-requests: write` | `GITHUB_TOKEN` (default) |

## `lint.yml`

### Triggers

- `workflow_dispatch`, `pull_request`
- `push` to `main`

### What it does

Faithful CI reproduction of local developer checks:

1. `ci/install-lint-tools.sh` — installs pinned `actionlint`, `ansible-core`,
   `ansible-lint`, the `ansible.posix` and `community.general` Ansible
   collections, `yamllint`, `shellcheck`, and `bats` (versions from
   `versions.yml`; actionlint tarball verified against `actionlint_sha256`).
2. `actions/setup-node` with `node_ci_version` from `versions.yml`.
3. `make check` — `yamllint`, `ansible-lint`, `shellcheck`, Ansible playbook
   `--syntax-check`, bats, and the vitest suite under `e2b/templates`.
4. `actionlint` on `.github/workflows/*.yml`.

### Permissions and secrets

| Job | `permissions` | Secrets |
|---|---|---|
| `check` | `contents: read` | none |

## `installer-matrix.yml`

### Triggers

- `workflow_dispatch`
- `push` to `main` and `pull_request` when `versions.yml`, `ansible/**`, `bootstrap.sh`,
  `ci/matrix/**`, `e2b/**`, or this workflow changes.

### Gate (secrets and fork safety)

Job `gate` runs `ci/matrix/gate-secrets.sh`:

- **Skips** (success with summary, no install) when `QOPS_CI_LLM_API_KEY` or
  `QOPS_CI_CANARY_REPO_TOKEN` is missing.
- **Skips** fork pull requests (`GITHUB_HEAD_REPOSITORY != GITHUB_REPOSITORY`) so untrusted
  PR code never receives secrets. Does **not** use `pull_request_target`.

Optional repository variable: `QOPS_CI_CANARY_REPO` (`owner/name`) — used only to verify the
canary token can read the repo after the synthetic webhook POST.

### Ubuntu 24.04 leg (`ubuntu-2404` job)

Runs on `ubuntu-24.04` (KVM available). Each verification is a separate step with its own
summary line via `ci/matrix/step-summary.sh`.

| Step | What it exercises |
|---|---|
| `stage-artifacts.sh` | Build E2B dist (`e2b/build/build.sh`) + mirror FC artifacts locally |
| `prepare-host.sh` | TLS (provided), wildcard DNS (`wildcard-dns.py` for `*.e2b.<domain>` / `*.<domain>`), `10.255.0.1` on lo, dummy `:80` until Traefik, KVM/nbd modules |
| `run-bootstrap.sh --playbook site` | Full M1 install on localhost |
| `run-bootstrap.sh --playbook doctor` | `qops-doctor` including E2B smoke + isolation probe |
| `kodus-smoke.sh` | Loopback health + `synthetic-github-webhook.sh` |
| `check-idempotency.sh` | Second `site.yml` with `changed=0`, no template build |
| `check-dist-pair-mismatch.sh` | `e2b-assert-dist-pair.sh` rejects tampered `BUILD_INFO` |
| `check-orchestrator-restart.sh` | Create sandboxes, assert live ns/veth/nbd/cgroup, restart, assert cleanup (fail if create fails) |
| `check-upgrade.sh` | `upgrade.yml` at the **same** pin (backup, verify, migrate) |
| `check-reboot-skip.sh` | Documents reboot gate as **not runnable** on GH runners |

CI inventory: `ci/matrix/inventory-localhost.yml` + `ci/matrix/group_vars/codereviewer.yml`
(relaxed preflight thresholds — **not** for production).

### Synthetic webhook (`ci/matrix/synthetic-github-webhook.sh`)

**Proves:** Traefik routes `kodus-webhooks.<domain>`, TLS terminates, handler accepts a
signed GitHub `pull_request` payload (HTTP 2xx).

**Does not prove:** GitHub inbound delivery, Cloudflare Tunnel, canary PR review, graph-stage
comments, or 700 s streamed `commands.run`.

### Permissions and secrets

| Job | `permissions` | Secrets |
|---|---|---|
| `gate`, `skip-report` | `contents: read` | none |
| `ubuntu-2404` | `contents: read` | `QOPS_CI_LLM_API_KEY`, `QOPS_CI_CANARY_REPO_TOKEN` |

### Not covered on GitHub-hosted runners

- Reboot → `doctor.yml` persistence (no reboot API)
- Upgrade from a **previous** `versions.yml` dist (needs two published releases)
- 10 parallel reviews / `max-starting-instances-per-node` throttling
- 700 s public `commands.run` / WebSocket soak
- Full canary PR review with cross-file AST context
- Ubuntu 26.04 / Fedora 44 legs (M2 self-hosted runners)

## How to bump a pin manually

1. Edit `versions.yml` (and keep `e2b/e2b.pin` in sync — bats enforces equality).
2. Open a PR; `lint` and `build-e2b` run on path filters.
3. Merge after CI is green.

Or wait for / run `pin-bump.yml` to open an automated upstream pin PR.

## How to cut a release

1. Ensure `versions.yml` on the default branch reflects the pin you want.
2. Actions → **Build E2B dist** → **Run workflow** (`workflow_dispatch`).
3. When green, the workflow creates GitHub Release `e2b-<e2b_dist_version>` with
   the four assets listed above. Existing tags are rejected.

Ordinary pushes and PRs build and validate only; they never publish.

## Local verification (no Docker)

```bash
export PATH="$HOME/.local/bin:$PATH"
actionlint
yamllint .
bats tests/bats/
make check
./e2b/build/build.sh --dry-run
./ci/mirror-e2b-artifacts.sh --out /tmp/e2b-artifacts   # network; no Docker
```

## What remains untested

- `e2b/build/build.sh` full Docker compile on a runner
- `ci/validate-e2b-dist.sh` against a real dist tarball (needs the Docker build)
- Workflow artifact upload/download between jobs
- GitHub Release creation and asset layout as consumed by Ansible
- `pin-bump.yml` cloning upstream and opening a PR
- `lint.yml` on GitHub-hosted runners (Node/ansible toolchain differences)
- Scheduled cron execution
- `installer-matrix.yml` full install on a GitHub runner (first run pending secrets + KVM job)
- Synthetic webhook → real Kodus review pipeline end-to-end
