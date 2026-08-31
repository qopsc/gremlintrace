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

After reserving normal RAM (upstream `init-client.sh` algorithm), the script sets:

- `vm.nr_hugepages` = `percentage`% of the computable hugepage count (permanent pool)
- `vm.nr_overcommit_hugepages` = `(100 - percentage)`% (overcommit pool)

Page size is read from `/proc/meminfo` `Hugepagesize`. The script reads back both sysctls and fails on allocation shortfall. **Re-run determinism on a live host is unverified** (fragmentation can reduce what the kernel grants).

## Orchestrator storage

- `e2b_data_device` set: XFS formatted (if needed) and mounted at `/orchestrator` with `nofail`.
- No device: `/var/lib/e2b/orchestrator` bind-mounted to `/orchestrator` with `bind,nofail`.

Subdirectories are created **after** the mount is in place.

## Firecracker artifacts

Source (first match):

1. `e2b_host_fc_artifacts_local_path` — pre-staged archive
2. `qops_release_base_url` + `/e2b-fc-artifacts-<e2b_dist_version>.tar.gz`
3. `e2b_host_fc_artifacts_download_url`

`verify-fc-artifacts.sh` checks all three binaries against the archive `SHA256SUMS` before skipping install.

Implemented in **Task 6** (see `../../../docs/superpowers/specs/2026-08-28-kodus-e2b-selfhost-design.md`, Phase 2).
