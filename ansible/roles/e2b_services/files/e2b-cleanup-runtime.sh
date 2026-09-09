#!/usr/bin/env bash
# Remove E2B leftover runtime state: E2B nftables table, netns ns-*, veth-*, cgroup.
# Best-effort: every class of cleanup is attempted; individual misses are logged.
set -u

NFT_BIN="${QOPS_UNINSTALL_NFT:-nft}"
IP_BIN="${QOPS_UNINSTALL_IP:-ip}"
TABLES_RAW="${QOPS_UNINSTALL_E2B_NFT_TABLES:-v2-host-firewall}"
NETNS_DIR="${QOPS_UNINSTALL_NETNS_DIR:-/run/netns}"
SYS_CLASS_NET="${QOPS_UNINSTALL_SYS_CLASS_NET:-/sys/class/net}"
CGROUP_ROOT="${QOPS_UNINSTALL_CGROUP:-/sys/fs/cgroup/e2b}"
LOG="${QOPS_UNINSTALL_LOG:-}"

attempted=0
log() {
  printf '%s\n' "$1"
  if [[ -n "${LOG}" ]]; then
    printf '%s\n' "$1" >>"${LOG}"
  fi
}

IFS=',' read -r -a NFT_TABLES <<<"${TABLES_RAW}"
for table in "${NFT_TABLES[@]}"; do
  if [[ ! "${table}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    log "skip invalid E2B nft table name: ${table}"
    continue
  fi
  attempted=$((attempted + 1))
  log "attempt nft delete table inet ${table}"
  if ! "${NFT_BIN}" delete table inet "${table}" 2>/dev/null; then
    log "nft table inet ${table} absent or delete failed"
  fi
done

if [[ -d "${NETNS_DIR}" ]]; then
  shopt -s nullglob
  for ns_path in "${NETNS_DIR}"/ns-*; do
    [[ -e "${ns_path}" ]] || continue
    name="$(basename "${ns_path}")"
    attempted=$((attempted + 1))
    log "attempt ip netns delete ${name}"
    if ! "${IP_BIN}" netns delete "${name}" 2>/dev/null; then
      log "netns delete failed: ${name}"
    fi
  done
  shopt -u nullglob
else
  log "attempt netns cleanup skipped (missing ${NETNS_DIR})"
fi

if [[ -d "${SYS_CLASS_NET}" ]]; then
  shopt -s nullglob
  for veth_path in "${SYS_CLASS_NET}"/veth-*; do
    [[ -e "${veth_path}" ]] || continue
    name="$(basename "${veth_path}")"
    attempted=$((attempted + 1))
    log "attempt ip link delete ${name}"
    if ! "${IP_BIN}" link delete "${name}" 2>/dev/null; then
      log "veth delete failed: ${name}"
    fi
  done
  shopt -u nullglob
else
  log "attempt veth cleanup skipped (missing ${SYS_CLASS_NET})"
fi

attempted=$((attempted + 1))
log "attempt cgroup cleanup ${CGROUP_ROOT}"
if [[ -e "${CGROUP_ROOT}" ]]; then
  if [[ -d "${CGROUP_ROOT}" ]]; then
    find "${CGROUP_ROOT}" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null \
      | while IFS= read -r child; do
          rmdir "${child}" 2>/dev/null || rm -rf "${child}" 2>/dev/null || true
        done
    rmdir "${CGROUP_ROOT}" 2>/dev/null || rm -rf "${CGROUP_ROOT}" 2>/dev/null || true
  else
    rm -f "${CGROUP_ROOT}" 2>/dev/null || true
  fi
else
  log "cgroup path absent: ${CGROUP_ROOT}"
fi

log "runtime cleanup attempted=${attempted}"
exit 0
