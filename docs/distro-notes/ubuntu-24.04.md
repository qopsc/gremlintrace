# Ubuntu 24.04 (M1)

## Milestone support

| Item | M1 status |
|---|---|
| Installer target | **Supported** — first and only distro-family path in M1 |
| CI matrix leg | `installer-matrix.yml` `ubuntu-24.04` on GitHub-hosted runners (KVM available) |
| `tls_mode` | `acme_dns`, `provided` |
| `e2b_storage_backend` | `local` only |
| `backup_target` | `local` only (`qops-backup` timer via `site.yml`) |

Ubuntu **26.04** and **Fedora 44** are **M2** (self-hosted nested-virt runners, distro-specific package names). The `common` role **rejects non-Debian families** today (`ansible/roles/common`).

## Packages and modules

| Need | Ubuntu 24.04 approach |
|---|---|
| Docker Engine | `download.docker.com` Ubuntu repo (`docker` role) |
| nftables | `nftables` package (`host_firewall`) |
| `nbd` | `modprobe nbd`; kernel module in default 24.04 kernel (no `linux-modules-extra` metapackage unlike 26.04) |
| Firecracker host | `/dev/kvm`, hugetlbfs, `e2b-hugepages.service` |
| Node for templates | Host Node 22 or one-shot `node:<node_ci_version>` container |

## Preflight defaults (production)

| Check | Default |
|---|---|
| vCPU | ≥ 8 |
| RAM | ≥ 32 GiB |
| Disk | ≥ 200 GiB free on orchestrator path |
| glibc | ≥ 2.36 |
| Kernel | ≥ 6.1, `nbd` loadable |

CI matrix lowers CPU/RAM/disk thresholds via `ci/matrix/group_vars/codereviewer.yml` — **do not copy CI overrides to customer installs**.

## Kernel updates

`unattended-upgrades` is configured with `Automatic-Reboot=false`. After kernel updates, operator must reboot and verify `nbd.ko` for the new kernel (`qops-doctor` `nbd_ko_newest_kernel`).

## CI leg notes

- Workflow: `.github/workflows/installer-matrix.yml`
- Inventory: `ci/matrix/inventory-localhost.yml`
- Requires repository secrets on non-fork PRs / default branch
- Relaxed preflight and `tls_mode: provided` with generated certs
- **Never executed in this dev environment** (no Docker/KVM here); first run will be on GitHub Actions

## What is not verified on Ubuntu 24.04

- Real customer install with ACME DNS-01
- Medium-load concurrent reviews
- Phase 0 exit criteria (`docs/spike-notes.md`)
