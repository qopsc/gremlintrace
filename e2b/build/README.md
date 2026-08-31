# E2B build pipeline

Produces `e2b/build/dist/e2b-<e2b_dist_version>.tar.gz` from the pinned
`e2b-dev/infra` commit (`versions.yml:e2b_pin` / `e2b/e2b.pin`) plus any files in
`e2b/patches/*.patch`.

**The real Docker build has never been executed on this machine.** There is no
Docker daemon here. `build.sh --dry-run` and the bats suite (Docker stubbed, no
network) are what this host can run. The full image build, Go compile, linkage
assertions, and tarball assembly are exercised only by the CI workflow in task 3
(`ci/build-e2b.yml`).

## How to run a real build

On an x86_64 Linux host with Docker (CI runner, or a developer machine):

```bash
./e2b/build/build.sh
```

That will:

1. Read every pin from `versions.yml` (authoritative). Abort if `e2b/e2b.pin`
   disagrees with `e2b_pin`, or if `e2b_dist_version` is not the first 7
   characters of `e2b_pin`.
2. Clone `e2b-dev/infra` at `e2b_pin` into a scratch directory (never into this
   repo), verify `HEAD` equals the pin, and `git apply` every `e2b/patches/*.patch`
   in lexical order (empty `patches/` is a no-op; a literal `*.patch` glob is not
   applied).
3. `docker build` `Dockerfile.build` tagged
   `codereviewer-e2b-build:<e2b_go_version>` (never `latest`), then `docker run`
   to compile and pack.

Inputs are overridable for tests: `--versions`, `--pin-file`, `--patches`,
`--src`, `--dist`. `DOCKER` and `GIT` environment variables are the only way the
script invokes those tools.

Validate without Docker or network:

```bash
./e2b/build/build.sh --dry-run
```

`--dry-run` prints the resolved `e2b_pin`, `e2b_go_version`, `e2b_dist_version`,
tarball filename, image tag, and patch list, then exits 0.

## Tarball contents

`dist/e2b-<e2b_dist_version>.tar.gz` contains exactly:

| Path | Source |
|---|---|
| `bin/orchestrator` | `packages/orchestrator` (`make build-local`, CGO, glibc-dynamic) |
| `bin/clean-nfs-cache` | `packages/orchestrator/cmd/clean-nfs-cache` (same make target; omitted only if that path is absent at the pin) |
| `bin/api` | `packages/api` (`make build`, `CGO_ENABLED=0`, `expectedMigrationTimestamp` ldflag) |
| `bin/client-proxy` | `packages/client-proxy` (`make build`, `CGO_ENABLED=0`) |
| `bin/envd` | `packages/envd` (`make build`, static, release `-s -w -buildid=`) |
| `bin/e2b-seed` | `packages/db/scripts/seed/postgres/seed-db.go` |
| `bin/goose` | `github.com/pressly/goose/v3/cmd/goose` built from `packages/db` so the version matches `go.mod` |
| `migrations/postgres/*.sql` | `packages/db/migrations` |
| `migrations/clickhouse/*.sql` | `packages/clickhouse/migrations` |
| `otel-collector.yaml` | `packages/otel-collector/tests/otel-collector.yaml` (the config E2B CI runs via `packages/otel-collector` `make run`) |
| `BUILD_INFO` | JSON provenance (keys below) |
| `SHA256SUMS` | checksums of every other file in the tarball |

After extraction, `sha256sum -c SHA256SUMS` must succeed. `SHA256SUMS` does not
list itself.

Firecracker / kernel / busybox artifacts are **not** in this tarball; task 3
mirrors those next to the dist.

## `BUILD_INFO` keys

JSON object. Stable key names — later tasks parse this file:

| Key | Meaning | Consumers |
|---|---|---|
| `e2b_pin` | Full upstream commit SHA | Installer provenance; must match `versions.yml` |
| `e2b_dist_version` | First 7 chars of the pin; tarball name | Ansible `e2b_dist_version` download |
| `e2b_go_version` | Go toolchain used for the build | Debugging / rebuild |
| `envd_version` | From `packages/envd/pkg/version.go` (must equal `versions.yml`) | **`upgrade.yml` compares this to decide whether templates must be rebuilt** |
| `goose_version` | From `packages/db/go.mod` (must equal `versions.yml`) | Migrator binary identity |
| `expected_migration_timestamp` | Newest `packages/db/migrations` prefix, same formula as `packages/api/Makefile` (`ls \| sed 's/_.*//' \| sort \| tail -n 1`) | Must match the timestamp baked into `bin/api`; the API refuses to start against a different DB |
| `built_at_utc` | ISO-8601 UTC timestamp of the compile (`YYYY-MM-DDTHH:MM:SSZ`) | Provenance |
| `clean_nfs_cache` | JSON boolean; whether `bin/clean-nfs-cache` is in the tarball | Installer |
| `patches` | Array of `{filename, sha256}` in lexical apply order; `[]` when empty | Pin-bump / audit |

## Dockerfile caching

`Dockerfile.build` is a **toolchain image only**: `golang:<e2b_go_version>-bookworm`
plus git, make, gcc/libc headers, and `file`. It does **not** clone upstream at
image-build time.

Pin and patches change more often than the Go minor. Cloning in `docker build`
would invalidate the apt/Go layer on every bump. `build.sh` clones (or uses
`--src`) on the host, applies patches there, and bind-mounts the checkout into
`docker run`. The image is retagged with `e2b_go_version`, so a Go bump produces
a new image without using `latest`. Named volumes `codereviewer-e2b-gomod` and
`codereviewer-e2b-gocache` persist module/build caches across pin bumps.

`E2B_PIN` is accepted as a build `ARG` (and exported into the image env) even
though the clone happens on the host — callers pass it from `versions.yml`.

## What is untested here

The following is written but has **not** been run on this machine (no Docker,
no `/dev/kvm`):

- `docker build` of `Dockerfile.build`
- `docker run` of the compile entrypoint (`build.sh --compile`)
- Actual `go build` / `make` of orchestrator, api, client-proxy, envd, e2b-seed,
  goose, clean-nfs-cache
- Linkage assertions (`file` / `ldd` on the real binaries)
- Tarball assembly, `SHA256SUMS` round-trip on a real dist, `BUILD_INFO`
  contents from a real compile
- `git clone` of `e2b-dev/infra` (bats stubs `git` and uses `--src`)
- Patch application against a real upstream tree (`git apply` is stubbed)

Verified on this machine: `build.sh --dry-run`, pin-mismatch abort, lexical
patch loop + apply failure, empty `patches/` glob, Docker not called in
`--dry-run`, Dockerfile has no hard-coded Go version, `shellcheck` on
`build.sh`.
