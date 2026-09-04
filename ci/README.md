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
| Restore drill | `.github/workflows/restore-drill.yml` | M2 |

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
