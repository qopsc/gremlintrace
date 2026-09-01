#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export ANSIBLE_CONFIG="${REPO_ROOT}/ansible.cfg"
  export ANSIBLE_HOST_KEY_CHECKING=False
  INVENTORY="${REPO_ROOT}/tests/fixtures/inventory-codereviewer-local.yml"
  UNINSTALL_PB="${REPO_ROOT}/ansible/playbooks/uninstall.yml"
  UNINSTALL="${REPO_ROOT}/ansible/roles/backup/files/qops-uninstall.sh"
  CLEANUP="${REPO_ROOT}/ansible/roles/e2b_services/files/e2b-cleanup-runtime.sh"
}

@test "uninstall.yml requires qops_uninstall_confirm" {
  run grep -n 'qops_uninstall_confirm' "${UNINSTALL_PB}" "${REPO_ROOT}/ansible/group_vars/all.yml"
  [ "$status" -eq 0 ]
  grep -q 'qops_uninstall_confirm: false' "${REPO_ROOT}/ansible/group_vars/all.yml"
  grep -q 'qops_uninstall_destroy_data: false' "${REPO_ROOT}/ansible/group_vars/all.yml"
  run ansible-playbook --check -i "${INVENTORY}" "${UNINSTALL_PB}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"qops_uninstall_confirm"* ]]
}

@test "uninstall helper refuses to run without --confirm" {
  run bash "${UNINSTALL}"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--confirm"* ]]
}

@test "data is preserved by default" {
  root="${BATS_TMPDIR}/uninst"
  data="${root}/data"
  software="${root}/software"
  mkdir -p "${data}/keep" "${software}/bin"
  printf 'secret\n' >"${data}/keep/x"
  log="${root}/log"
  run env \
    QOPS_UNINSTALL_LOG="${log}" \
    QOPS_UNINSTALL_CLEANUP="${CLEANUP}" \
    QOPS_UNINSTALL_SYSTEMCTL="/bin/true" \
    QOPS_UNINSTALL_DOCKER="/bin/true" \
    QOPS_UNINSTALL_DATA_PATHS="${data}" \
    QOPS_UNINSTALL_SOFTWARE_PATHS="${software}" \
    QOPS_UNINSTALL_NFT="$(command -v true)" \
    QOPS_UNINSTALL_IP="$(command -v true)" \
    QOPS_UNINSTALL_NETNS_DIR="${root}/netns" \
    QOPS_UNINSTALL_SYS_CLASS_NET="${root}/net" \
    QOPS_UNINSTALL_CGROUP="${root}/cgroup" \
    bash "${UNINSTALL}" --confirm
  [ "$status" -eq 0 ]
  [ -d "${data}/keep" ]
  [ ! -d "${software}" ]
  grep -q 'preserving data' "${log}"
}

@test "destroy-data removes preserved paths" {
  root="${BATS_TMPDIR}/uninst-destroy"
  data="${root}/data"
  mkdir -p "${data}/keep" "${root}/netns" "${root}/net" "${root}/cgroup"
  run env \
    QOPS_UNINSTALL_LOG="${root}/log" \
    QOPS_UNINSTALL_CLEANUP="${CLEANUP}" \
    QOPS_UNINSTALL_SYSTEMCTL="/bin/true" \
    QOPS_UNINSTALL_DOCKER="/bin/true" \
    QOPS_UNINSTALL_DATA_PATHS="${data}" \
    QOPS_UNINSTALL_SOFTWARE_PATHS="${root}/software-missing" \
    QOPS_UNINSTALL_NFT="$(command -v true)" \
    QOPS_UNINSTALL_IP="$(command -v true)" \
    QOPS_UNINSTALL_NETNS_DIR="${root}/netns" \
    QOPS_UNINSTALL_SYS_CLASS_NET="${root}/net" \
    QOPS_UNINSTALL_CGROUP="${root}/cgroup" \
    bash "${UNINSTALL}" --confirm --destroy-data
  [ "$status" -eq 0 ]
  [ ! -d "${data}" ]
}

@test "nftables, netns, veth, and cgroup cleanup are all attempted" {
  root="${BATS_TMPDIR}/runtime"
  netns="${root}/netns"
  veth="${root}/net"
  cgroup="${root}/cgroup/e2b"
  mkdir -p "${netns}" "${veth}/veth-abc" "${cgroup}/sbx-1"
  : >"${netns}/ns-deadbeef"
  nft_log="${root}/nft.log"
  ip_log="${root}/ip.log"
  cat >"${root}/nft" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${nft_log}"
exit 0
EOF
  cat >"${root}/ip" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${ip_log}"
exit 0
EOF
  chmod +x "${root}/nft" "${root}/ip"
  run env \
    QOPS_UNINSTALL_NFT="${root}/nft" \
    QOPS_UNINSTALL_IP="${root}/ip" \
    QOPS_UNINSTALL_NFT_TABLE="qops_filter" \
    QOPS_UNINSTALL_NETNS_DIR="${netns}" \
    QOPS_UNINSTALL_SYS_CLASS_NET="${veth}" \
    QOPS_UNINSTALL_CGROUP="${cgroup}" \
    QOPS_UNINSTALL_LOG="${root}/cleanup.log" \
    bash "${CLEANUP}"
  [ "$status" -eq 0 ]
  grep -q 'delete table inet qops_filter' "${nft_log}"
  grep -q 'netns delete ns-deadbeef' "${ip_log}"
  grep -q 'link delete veth-abc' "${ip_log}"
  grep -q "attempt cgroup cleanup ${cgroup}" "${root}/cleanup.log"
  [ ! -d "${cgroup}" ]
}

@test "uninstall.yml wires nftables table, netns, veth, and cgroup cleanup" {
  grep -q 'e2b-cleanup-runtime.sh' "${UNINSTALL_PB}"
  grep -q 'qops_filter' "${UNINSTALL_PB}"
  grep -q 'qops-uninstall' "${UNINSTALL_PB}"
  grep -q 'ns-\*' "${CLEANUP}"
  grep -q 'veth-\*' "${CLEANUP}"
  grep -q '/sys/fs/cgroup/e2b' "${CLEANUP}"
}

@test "runtime cleanup runs after orchestrator is stopped and verified inactive" {
  root="${BATS_TEST_TMPDIR:-${BATS_TMPDIR}}/uninstall-order"
  rm -rf "${root}"
  mkdir -p "${root}"
  log="${root}/log"
  sys="${root}/systemctl"
  cat >"${sys}" <<EOF
#!/usr/bin/env bash
printf 'systemctl %s\n' "\$*" >>"${log}"
if [[ "\$1" == "is-active" ]]; then
  printf 'inactive\n'
fi
exit 0
EOF
  chmod +x "${sys}"
  cleanup_wrap="${root}/cleanup.sh"
  cat >"${cleanup_wrap}" <<EOF
#!/usr/bin/env bash
printf 'cleanup-start\n' >>"${log}"
bash "${CLEANUP}"
printf 'cleanup-end\n' >>"${log}"
EOF
  chmod +x "${cleanup_wrap}"
  run env \
    QOPS_UNINSTALL_LOG="${log}" \
    QOPS_UNINSTALL_CLEANUP="${cleanup_wrap}" \
    QOPS_UNINSTALL_SYSTEMCTL="${sys}" \
    QOPS_UNINSTALL_DOCKER="/bin/true" \
    QOPS_UNINSTALL_DATA_PATHS="${root}/data" \
    QOPS_UNINSTALL_SOFTWARE_PATHS="${root}/software-missing" \
    QOPS_UNINSTALL_NFT="$(command -v true)" \
    QOPS_UNINSTALL_IP="$(command -v true)" \
    QOPS_UNINSTALL_NETNS_DIR="${root}/netns" \
    QOPS_UNINSTALL_SYS_CLASS_NET="${root}/net" \
    QOPS_UNINSTALL_CGROUP="${root}/cgroup" \
    bash "${UNINSTALL}" --confirm
  [ "$status" -eq 0 ]
  python3 - "${log}" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read().splitlines()
stop = next(
    i
    for i, line in enumerate(text)
    if line.startswith("attempt stop") and "e2b-orchestrator" in line
)
verified = next(
    i
    for i, line in enumerate(text)
    if line.startswith("verified") and "inactive" in line
)
cleanup = next(i for i, line in enumerate(text) if line == "cleanup-start")
assert stop < verified < cleanup, (stop, verified, cleanup, text)
print("ok")
PY
}

@test "destroy-data is aborted if orchestrator stop fails" {
  root="${BATS_TMPDIR}/abort-destroy"
  data="${root}/data"
  mkdir -p "${data}/keep"
  printf 'secret\n' >"${data}/keep/x"
  sys="${root}/systemctl"
  cat >"${sys}" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "stop" && "$2" == "e2b-orchestrator.service" ]]; then
  echo "stop failed" >&2
  exit 1
fi
exit 0
EOF
  chmod +x "${sys}"
  run env \
    QOPS_UNINSTALL_LOG="${root}/log" \
    QOPS_UNINSTALL_CLEANUP="${CLEANUP}" \
    QOPS_UNINSTALL_SYSTEMCTL="${sys}" \
    QOPS_UNINSTALL_DOCKER="/bin/true" \
    QOPS_UNINSTALL_DATA_PATHS="${data}" \
    QOPS_UNINSTALL_SOFTWARE_PATHS="${root}/software-missing" \
    QOPS_UNINSTALL_NFT="$(command -v true)" \
    QOPS_UNINSTALL_IP="$(command -v true)" \
    QOPS_UNINSTALL_NETNS_DIR="${root}/netns" \
    QOPS_UNINSTALL_SYS_CLASS_NET="${root}/net" \
    QOPS_UNINSTALL_CGROUP="${root}/cgroup" \
    bash "${UNINSTALL}" --confirm --destroy-data
  [ "$status" -ne 0 ]
  [ -d "${data}/keep" ]
  grep -q 'aborting destroy-data' "${root}/log"
}
