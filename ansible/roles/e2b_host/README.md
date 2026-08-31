# e2b_host

Host prep for Firecracker: nbd, hugetlbfs, swap, `/orchestrator`, and mirrored FC/kernel/busybox artifacts.

## Paths (task 7+ interface)

| Path | Purpose |
|---|---|
| `/orchestrator/{sandbox,template,build}` | Orchestrator local storage roots |
| `/mnt/hugepages` | hugetlbfs mount (`e2b_host_hugepages_mount`) |
| `/fc-versions/<firecracker_version>/amd64/firecracker` | Firecracker binary |
| `/fc-kernels/<kernel_version>/amd64/vmlinux.bin` | Guest kernel |
| `/fc-busybox/<busybox_version>/amd64/busybox` | Busybox initramfs helper |
| `/fc-envd`, `/fc-vm` | envd binary (task 7) and FC runtime scratch |

## Hugepages split

`e2b-hugepages.service` (before `docker.service`) runs `/usr/local/lib/qops/e2b-allocate-hugepages.sh` with `E2B_HUGEPAGES_PERCENTAGE` from `e2b_hugepages_percentage` (default **80**).

After reserving normal RAM (same algorithm as upstream `init-client.sh`), the script sets:

- `vm.nr_hugepages` = `percentage`% of the computable hugepage count (permanent pool)
- `vm.nr_overcommit_hugepages` = `(100 - percentage)`% (overcommit pool)

Re-runs are deterministic: the same inputs write the same sysctl values.

## Firecracker artifacts

Source (first match):

1. `e2b_host_fc_artifacts_local_path` — pre-staged `e2b-fc-artifacts-<e2b_dist_version>.tar.gz`
2. `e2b_host_fc_artifacts_download_url` — downloaded to `/var/cache/qops/`

Tarball layout matches CI (`firecrackers/`, `kernels/`, `busybox/`, inner `SHA256SUMS`). Install is skipped when `firecracker` already exists at the pinned version path.

Implemented in **Task 6** (see `../../../docs/superpowers/specs/2026-08-28-kodus-e2b-selfhost-design.md`, Phase 2).
