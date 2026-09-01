#!/usr/bin/env bash
# Remove software (units, binaries, E2B runtime leftovers). Data is preserved
# unless --destroy-data is passed. Refuses to run without --confirm.
#
# Ordering: stop and verify e2b-orchestrator is inactive, then nftables/netns/
# veth/cgroup cleanup. Abort (including destroy-data) if that stop fails.
set -euo pipefail

CONFIRM=0
DESTROY_DATA=0
DRY_RUN=0

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --confirm) CONFIRM=1 ;;
    --destroy-data) DESTROY_DATA=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      echo "usage: qops-uninstall.sh --confirm [--destroy-data] [--dry-run]" >&2
      exit 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

if [[ "${CONFIRM}" -ne 1 ]]; then
  echo "Refusing to uninstall. Pass --confirm (playbook: -e qops_uninstall_confirm=true)." >&2
  exit 2
fi

SYSTEMCTL="${QOPS_UNINSTALL_SYSTEMCTL:-systemctl}"
DOCKER_BIN="${QOPS_UNINSTALL_DOCKER:-docker}"
CLEANUP="${QOPS_UNINSTALL_CLEANUP:-/usr/local/lib/qops/e2b-cleanup-runtime.sh}"
KODUS_DIR="${QOPS_UNINSTALL_KODUS_DIR:-/opt/kodus-installer}"
E2B_COMPOSE="${QOPS_UNINSTALL_E2B_COMPOSE:-/etc/qops/e2b-data/docker-compose.yml}"
E2B_PROJECT="${QOPS_UNINSTALL_E2B_PROJECT:-e2b-data}"
SECRETS="${QOPS_UNINSTALL_SECRETS:-/etc/qops/secrets.env}"
LOG="${QOPS_UNINSTALL_LOG:-}"
ORCH_UNIT="${QOPS_UNINSTALL_ORCHESTRATOR_UNIT:-e2b-orchestrator.service}"

DATA_PATHS=(
  "${QOPS_UNINSTALL_E2B_LIB:-/var/lib/e2b}"
  "${QOPS_UNINSTALL_ORCHESTRATOR:-/orchestrator}"
  "${QOPS_UNINSTALL_QOPS:-/etc/qops}"
  "${QOPS_UNINSTALL_BACKUPS:-/var/backups/qops}"
)

SOFTWARE_PATHS=(
  "${QOPS_UNINSTALL_E2B_PREFIX:-/usr/local/lib/e2b}"
  "${QOPS_UNINSTALL_QOPS_LIB:-/usr/local/lib/qops}"
  "${QOPS_UNINSTALL_BACKUP_BIN:-/usr/local/bin/qops-backup}"
  "${QOPS_UNINSTALL_VERIFY_BIN:-/usr/local/bin/qops-backup-verify}"
  "${QOPS_UNINSTALL_GC_BIN:-/usr/local/bin/qops-e2b-gc}"
  "${QOPS_UNINSTALL_DOCTOR_BIN:-/usr/local/bin/qops-doctor}"
  "${QOPS_UNINSTALL_UNINSTALL_BIN:-/usr/local/bin/qops-uninstall}"
  "${QOPS_UNINSTALL_TRAEFIK_BIN:-/usr/local/bin/traefik}"
  "${QOPS_UNINSTALL_FC_VERSIONS:-/fc-versions}"
  "${QOPS_UNINSTALL_FC_KERNELS:-/fc-kernels}"
  "${QOPS_UNINSTALL_FC_BUSYBOX:-/fc-busybox}"
  "${QOPS_UNINSTALL_FC_ENVD:-/fc-envd}"
)

if [[ -n "${QOPS_UNINSTALL_DATA_PATHS:-}" ]]; then
  read -r -a DATA_PATHS <<<"${QOPS_UNINSTALL_DATA_PATHS}"
fi
if [[ -n "${QOPS_UNINSTALL_SOFTWARE_PATHS:-}" ]]; then
  read -r -a SOFTWARE_PATHS <<<"${QOPS_UNINSTALL_SOFTWARE_PATHS}"
fi

UNITS=(
  e2b-orchestrator.service
  e2b-api.service
  e2b-client-proxy.service
  traefik.service
  e2b-hugepages.service
  qops-backup.timer
  qops-backup.service
  qops-e2b-gc.timer
  qops-e2b-gc.service
)

log() {
  printf '%s\n' "$1"
  if [[ -n "${LOG}" ]]; then
    printf '%s\n' "$1" >>"${LOG}"
  fi
}

run() {
  log "attempt $*"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    return 0
  fi
  "$@" || log "command failed (continuing): $*"
}

orchestrator_is_inactive() {
  local state
  state="$("${SYSTEMCTL}" is-active "${ORCH_UNIT}" 2>/dev/null || true)"
  case "${state}" in
    inactive|failed|unknown|"")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

abort_uninstall() {
  local msg="$1"
  log "abort: ${msg}"
  if [[ "${DESTROY_DATA}" -eq 1 ]]; then
    log "aborting destroy-data because ${ORCH_UNIT} is not inactive"
  fi
  echo "${msg}" >&2
  exit 1
}

# Stop units first. Orchestrator must be inactive before runtime cleanup
# or any destroy-data path.
log "attempt stop ${ORCH_UNIT} before leftover cleanup"
if [[ "${DRY_RUN}" -eq 0 ]]; then
  if ! "${SYSTEMCTL}" stop "${ORCH_UNIT}"; then
    abort_uninstall "failed to stop ${ORCH_UNIT}"
  fi
  if ! orchestrator_is_inactive; then
    abort_uninstall "${ORCH_UNIT} still active after stop; refusing runtime cleanup and destroy-data"
  fi
  log "verified ${ORCH_UNIT} inactive"
else
  log "attempt verify ${ORCH_UNIT} inactive (dry-run)"
fi

for unit in "${UNITS[@]}"; do
  if [[ "${unit}" == "${ORCH_UNIT}" ]]; then
    run "${SYSTEMCTL}" disable "${unit}"
    continue
  fi
  run "${SYSTEMCTL}" stop "${unit}"
  run "${SYSTEMCTL}" disable "${unit}"
done
run "${SYSTEMCTL}" daemon-reload

if [[ -x "${CLEANUP}" || -f "${CLEANUP}" ]]; then
  log "attempt runtime cleanup (nftables, netns, veth, cgroup) after ${ORCH_UNIT} inactive"
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    bash "${CLEANUP}" || log "runtime cleanup returned non-zero"
  fi
else
  log "attempt runtime cleanup skipped (missing ${CLEANUP})"
fi

if command -v "${DOCKER_BIN}" >/dev/null 2>&1 || [[ -x "${DOCKER_BIN}" ]]; then
  if [[ -f "${KODUS_DIR}/docker-compose.yml" ]]; then
    files=(-f "${KODUS_DIR}/docker-compose.yml")
    if [[ -f "${KODUS_DIR}/docker-compose.override.yml" ]]; then
      files+=(-f "${KODUS_DIR}/docker-compose.override.yml")
    fi
    if [[ "${DESTROY_DATA}" -eq 1 ]]; then
      run "${DOCKER_BIN}" compose --project-directory "${KODUS_DIR}" "${files[@]}" down -v
    else
      run "${DOCKER_BIN}" compose --project-directory "${KODUS_DIR}" "${files[@]}" down
    fi
  fi
  if [[ -f "${E2B_COMPOSE}" ]]; then
    if [[ "${DESTROY_DATA}" -eq 1 ]]; then
      run "${DOCKER_BIN}" compose --project-name "${E2B_PROJECT}" --env-file "${SECRETS}" \
        -f "${E2B_COMPOSE}" down -v
    else
      run "${DOCKER_BIN}" compose --project-name "${E2B_PROJECT}" --env-file "${SECRETS}" \
        -f "${E2B_COMPOSE}" down
    fi
  fi
fi

for path in "${SOFTWARE_PATHS[@]}"; do
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "attempt rm software ${path}"
    continue
  fi
  if [[ -e "${path}" ]]; then
    log "attempt rm software ${path}"
    rm -rf "${path}"
  fi
done

for unit in "${UNITS[@]}"; do
  unit_path="/etc/systemd/system/${unit}"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "attempt rm ${unit_path}"
    continue
  fi
  rm -f "${unit_path}"
done

if [[ "${DESTROY_DATA}" -eq 1 ]]; then
  log "destroy-data enabled"
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    rm -rf "${KODUS_DIR}"
  else
    log "attempt rm data ${KODUS_DIR}"
  fi
  for path in "${DATA_PATHS[@]}"; do
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "attempt rm data ${path}"
      continue
    fi
    log "attempt rm data ${path}"
    rm -rf "${path}"
  done
else
  log "preserving data (qops_uninstall_destroy_data=false)"
  for path in "${DATA_PATHS[@]}"; do
    log "preserved ${path}"
  done
fi

log "uninstall complete confirm=1 destroy_data=${DESTROY_DATA}"
