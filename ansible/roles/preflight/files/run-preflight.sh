#!/usr/bin/env bash
# Run codereviewer preflight checks; always writes a JSON report.
set -euo pipefail

REPORT_PATH="${PREFLIGHT_REPORT_PATH:-/etc/qops/preflight.json}"
SCHEMA_VERSION="${PREFLIGHT_SCHEMA_VERSION:-1}"
MIN_VCPUS="${PREFLIGHT_MIN_VCPUS:-8}"
MIN_RAM_MB="${PREFLIGHT_MIN_RAM_MB:-32768}"
MIN_DISK_GB="${PREFLIGHT_MIN_DISK_GB:-200}"
MIN_GLIBC="${PREFLIGHT_MIN_GLIBC:-2.36}"
MIN_KERNEL="${PREFLIGHT_MIN_KERNEL:-6.1}"
DATA_PATH="${PREFLIGHT_DATA_PATH:-/var/lib/e2b}"
QOPS_DOMAIN="${PREFLIGHT_QOPS_DOMAIN:-example.com}"
DNS_API_HOST="${PREFLIGHT_DNS_API_HOST:-api.e2b.${QOPS_DOMAIN}}"
DNS_RANDOM_HOST="${PREFLIGHT_DNS_RANDOM_HOST:-preflight-check.e2b.${QOPS_DOMAIN}}"
QOPS_MARKER_DIR="${PREFLIGHT_QOPS_MARKER_DIR:-/etc/qops}"
ALLOWED_PORT_22_UNITS="${PREFLIGHT_ALLOWED_PORT_22_UNITS:-ssh.service,sshd.service,ssh.socket,sshd.socket}"
ALLOWED_PORT_80_UNITS="${PREFLIGHT_ALLOWED_PORT_80_UNITS:-traefik.service}"
ALLOWED_PORT_443_UNITS="${PREFLIGHT_ALLOWED_PORT_443_UNITS:-traefik.service}"
EGRESS_URLS="${PREFLIGHT_EGRESS_URLS:-}"

CHECKS_STATE="$(mktemp)"
FAILURES_STATE="$(mktemp)"
trap 'rm -f "${CHECKS_STATE}" "${FAILURES_STATE}"' EXIT
printf '[]' >"${CHECKS_STATE}"
printf '[]' >"${FAILURES_STATE}"

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

add_check() {
  local id="$1" name="$2" passed="$3" message="$4"
  local details="$5"
  if [[ -z "${details}" ]]; then
    details='{}'
  fi
  python3 - "${CHECKS_STATE}" "${FAILURES_STATE}" "${id}" "${name}" "${passed}" "${message}" "${details}" <<'PY'
import json
import sys

checks_path, failures_path, check_id, name, passed, message, details_raw = sys.argv[1:8]
checks = json.load(open(checks_path))
details = json.loads(details_raw)
checks.append({
    "id": check_id,
    "name": name,
    "passed": passed == "true",
    "message": message,
    "details": details,
})
json.dump(checks, open(checks_path, "w"))
if passed != "true":
    failures = json.load(open(failures_path))
    failures.append(message)
    json.dump(failures, open(failures_path, "w"))
PY
}

version_ge() {
  python3 - "$1" "$2" <<'PY'
import sys
from functools import reduce

def parse(v):
    parts = []
    for chunk in v.strip().lstrip('v').split('.'):
        digits = ''.join(c for c in chunk if c.isdigit())
        parts.append(int(digits or 0))
    return parts

def ge(a, b):
    ap, bp = parse(a), parse(b)
    length = max(len(ap), len(bp))
    ap += [0] * (length - len(ap))
    bp += [0] * (length - len(bp))
    return ap >= bp

print('true' if ge(sys.argv[1], sys.argv[2]) else 'false')
PY
}

check_arch() {
  local arch
  arch="$(uname -m)"
  if [[ "${arch}" == "x86_64" ]]; then
    add_check "arch_x86_64" "CPU architecture" true "Host architecture is x86_64." "{\"arch\":\"${arch}\"}"
  else
    add_check "arch_x86_64" "CPU architecture" false \
      "Unsupported architecture ${arch}; codereviewer requires x86_64." "{\"arch\":\"${arch}\"}"
  fi
}

check_kvm() {
  local nested="unknown" kvm_ok=false msg details
  if [[ -e /dev/kvm ]]; then
  if [[ -r /dev/kvm && -w /dev/kvm ]]; then
      kvm_ok=true
      msg="KVM device /dev/kvm is present and usable."
    else
      msg="KVM device /dev/kvm exists but is not readable/writable; fix permissions or load kvm module."
    fi
  else
    msg="KVM device /dev/kvm is missing; enable hardware virtualization in firmware/BIOS and load the kvm module."
  fi
  if systemd-detect-virt -q 2>/dev/null; then
    if grep -q -E '(vmx|svm)' /proc/cpuinfo 2>/dev/null; then
      nested="enabled"
    else
      nested="disabled"
      if [[ "${kvm_ok}" == true ]]; then
        kvm_ok=false
        msg="Nested virtualization appears disabled on this VM; enable nested virt on the hypervisor and reboot."
      fi
    fi
  else
    nested="n/a"
  fi
  details="{\"nested_virtualization\":\"${nested}\"}"
  add_check "kvm" "KVM" "${kvm_ok}" "${msg}" "${details}"
}

check_cgroup_v2() {
  local passed=false msg="cgroup v2 is not active or cpu/memory controllers are missing from cgroup.subtree_control."
  local details="{}"
  if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
    local subtree
    subtree="$(tr '\t' ' ' < /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true)"
    if [[ "${subtree}" == *cpu* && "${subtree}" == *memory* ]]; then
      passed=true
      msg="cgroup v2 is active with cpu and memory in cgroup.subtree_control."
    fi
    details="{\"subtree_control\":\"${subtree}\"}"
  fi
  add_check "cgroup_v2" "cgroup v2" "${passed}" "${msg}" "${details}"
}

check_systemd() {
  local passed=false msg="PID 1 is not systemd; codereviewer requires systemd."
  if [[ "$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')" == "systemd" ]]; then
    passed=true
    msg="systemd is PID 1."
  fi
  add_check "systemd" "Init system" "${passed}" "${msg}" "{}"
}

check_glibc() {
  local version msg passed=false
  if version="$(ldd --version 2>/dev/null | head -n1 | awk '{print $NF}')"; then
    :
  else
    version="0"
  fi
  if [[ "$(version_ge "${version}" "${MIN_GLIBC}")" == "true" ]]; then
    passed=true
    msg="glibc ${version} meets minimum ${MIN_GLIBC}."
  else
    msg="glibc ${version} is below minimum ${MIN_GLIBC}; upgrade the host OS (orchestrator requires glibc >= ${MIN_GLIBC})."
  fi
  add_check "glibc" "glibc version" "${passed}" "${msg}" "{\"version\":\"${version}\",\"minimum\":\"${MIN_GLIBC}\"}"
}

check_kernel_nbd() {
  local kernel passed_kernel=false passed_nbd=false msg_kernel msg_nbd
  kernel="$(uname -r)"
  if [[ "$(version_ge "${kernel}" "${MIN_KERNEL}")" == "true" ]]; then
    passed_kernel=true
    msg_kernel="Kernel ${kernel} meets minimum ${MIN_KERNEL}."
  else
    msg_kernel="Kernel ${kernel} is below minimum ${MIN_KERNEL}; upgrade the running kernel."
  fi
  if modprobe -n nbd >/dev/null 2>&1; then
    passed_nbd=true
    msg_nbd="nbd module is loadable for the running kernel."
  else
    msg_nbd="nbd module is not loadable for kernel ${kernel}; install kernel-modules-extra (or equivalent) and reboot."
  fi
  local passed=false msg="${msg_kernel} ${msg_nbd}"
  if [[ "${passed_kernel}" == true && "${passed_nbd}" == true ]]; then
    passed=true
    msg="Kernel and nbd checks passed."
  fi
  local nbd_json="false"
  [[ "${passed_nbd}" == true ]] && nbd_json="true"
  add_check "kernel_nbd" "Kernel and nbd module" "${passed}" "${msg}" \
    "{\"kernel\":\"${kernel}\",\"minimum_kernel\":\"${MIN_KERNEL}\",\"nbd_loadable\":${nbd_json}}"
}

check_hugetlbfs() {
  local passed=false msg="hugetlbfs is not available; ensure CONFIG_HUGETLBFS is enabled."
  if grep -q hugetlbfs /proc/filesystems 2>/dev/null; then
    passed=true
    msg="hugetlbfs filesystem is available."
  fi
  add_check "hugetlbfs" "hugetlbfs" "${passed}" "${msg}" "{}"
}

check_resources() {
  local vcpus ram_mb disk_gb passed=true msg_parts=() details=()

  vcpus="$(nproc --all 2>/dev/null || echo 0)"
  if (( vcpus < MIN_VCPUS )); then
    passed=false
    msg_parts+=("need >= ${MIN_VCPUS} vCPU (found ${vcpus})")
  fi
  details+=("\"vcpus\":${vcpus}")

  ram_mb="$(awk '/MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo)"
  if (( ram_mb < MIN_RAM_MB )); then
    passed=false
    msg_parts+=("need >= ${MIN_RAM_MB} MiB RAM (found ${ram_mb})")
  fi
  details+=("\"ram_mb\":${ram_mb}")

  mkdir -p "${DATA_PATH}" 2>/dev/null || true
  disk_gb="$(df -BG --output=avail "${DATA_PATH}" 2>/dev/null | tail -n1 | tr -dc '0-9' || true)"
  if ! [[ "${disk_gb}" =~ ^[0-9]+$ ]]; then
    disk_gb=0
  fi
  if (( disk_gb < MIN_DISK_GB )); then
    passed=false
    msg_parts+=("need >= ${MIN_DISK_GB} GiB free on ${DATA_PATH} (found ${disk_gb})")
  fi
  details+=("\"disk_gb_free\":${disk_gb},\"data_path\":\"${DATA_PATH}\"")

  local msg
  if [[ "${passed}" == true ]]; then
    msg="Host meets CPU/RAM/disk minimums."
  else
    msg="Insufficient resources: $(IFS='; '; echo "${msg_parts[*]}")."
  fi
  add_check "resources" "CPU, RAM, and disk" "${passed}" "${msg}" "{$(IFS=,; echo "${details[*]}")}"
}

unit_allowed() {
  local unit_csv="$1" port="$2"
  local unit
  IFS=',' read -r -a allowed <<<"${unit_csv}"
  if ! command -v ss >/dev/null 2>&1; then
    return 1
  fi
  local line pid comm
  while read -r line; do
  [[ -n "${line}" ]] || continue
    if [[ "${line}" =~ pid=([0-9]+) ]]; then
      pid="${BASH_REMATCH[1]}"
      comm="$(ps -p "${pid}" -o comm= 2>/dev/null | tr -d ' ' || true)"
      for unit in "${allowed[@]}"; do
        unit="${unit// /}"
        [[ -z "${unit}" ]] && continue
        if systemctl status "${pid}" >/dev/null 2>&1; then
          if systemctl status "${pid}" 2>/dev/null | grep -q "${unit}"; then
            return 0
          fi
        fi
        if [[ "${comm}" == "${unit%.service}" ]]; then
          return 0
        fi
      done
      if [[ -d "${QOPS_MARKER_DIR}" ]]; then
        if tr '\0' ' ' </proc/"${pid}"/cmdline 2>/dev/null | grep -q traefik; then
          [[ "${port}" == "80" || "${port}" == "443" ]] && return 0
        fi
      fi
      return 1
    fi
  done < <(ss -H -tlnp "sport = :${port}" 2>/dev/null || true)
  return 0
}

check_port() {
  local port="$1" allowed_units="$2" check_id="$3" name="$4"
  local listeners passed=true msg
  listeners="$(ss -H -tln 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {print}' || true)"
  if [[ -z "${listeners}" ]]; then
    add_check "${check_id}" "${name}" true "Port ${port} is free." "{\"port\":${port}}"
    return
  fi
  if unit_allowed "${allowed_units}" "${port}"; then
    add_check "${check_id}" "${name}" true "Port ${port} is in use by an allowed qops service." "{\"port\":${port}}"
  else
    add_check "${check_id}" "${name}" false \
      "Port ${port} is in use by an unexpected process; stop it or reconfigure before install." \
      "{\"port\":${port},\"listeners\":$(printf '%s' "${listeners}" | json_escape)}"
  fi
}

host_ips() {
  python3 - <<'PY'
import json, subprocess
ips = set()
for fam, args in (("4", ["-4"]), ("6", ["-6"])):
    try:
        out = subprocess.check_output(["ip", *args, "addr", "show"], text=True)
    except Exception:
        continue
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("inet "):
            ips.add(line.split()[1].split("/")[0])
        elif line.startswith("inet6 ") and not line.split()[1].startswith("fe80"):
            ips.add(line.split()[1].split("/")[0])
print(json.dumps(sorted(ips)))
PY
}

check_dns() {
  local host_ips passed=true msg_parts=() host
  host_ips="$(host_ips)"
  for host in "${DNS_API_HOST}" "${DNS_RANDOM_HOST}"; do
    local addrs
    addrs="$(getent ahosts "${host}" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd, - || true)"
    if [[ -z "${addrs}" ]]; then
      passed=false
      msg_parts+=("${host} does not resolve")
      continue
    fi
    if ! python3 - "${host_ips}" "${addrs}" <<'PY'
import json, sys
host_ips = set(json.loads(sys.argv[1]))
resolved = [a.strip() for a in sys.argv[2].split(',') if a.strip()]
sys.exit(0 if any(a in host_ips for a in resolved) else 1)
PY
    then
      passed=false
      msg_parts+=("${host} resolves to ${addrs} but no address matches this host (${host_ips})")
    fi
  done
  local msg
  if [[ "${passed}" == true ]]; then
    msg="Wildcard E2B DNS records resolve to a host address."
  else
    msg="$(IFS='; '; echo "${msg_parts[*]}"). Configure api.e2b.${QOPS_DOMAIN} and *.e2b.${QOPS_DOMAIN} to point at this host."
  fi
  add_check "dns" "E2B DNS" "${passed}" "${msg}" \
    "{\"api_host\":\"${DNS_API_HOST}\",\"random_host\":\"${DNS_RANDOM_HOST}\",\"host_ips\":${host_ips}}"
}

check_egress() {
  local url passed=true msg_parts=()
  if [[ -z "${EGRESS_URLS}" ]]; then
    add_check "egress" "Egress reachability" false \
      "No egress URLs configured for this distribution family." "{}"
    return
  fi
  local IFS_backup="${IFS}"
  IFS='|'
  read -r -a urls <<<"${EGRESS_URLS}"
  IFS="${IFS_backup}"
  for url in "${urls[@]}"; do
    [[ -z "${url}" ]] && continue
    if ! curl -fsSIL --max-time 15 "${url}" >/dev/null 2>&1; then
      passed=false
      msg_parts+=("cannot reach ${url}")
    fi
  done
  local msg
  if [[ "${passed}" == true ]]; then
    msg="Required egress endpoints are reachable."
  else
    msg="Egress check failed: $(IFS='; '; echo "${msg_parts[*]}"). Allow outbound HTTPS to Docker registries, ghcr.io, bun.sh, and npm."
  fi
  add_check "egress" "Egress reachability" "${passed}" "${msg}" "{}"
}

write_report() {
  local passed="$1" ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  mkdir -p "$(dirname "${REPORT_PATH}")"
  python3 - "${REPORT_PATH}" "${SCHEMA_VERSION}" "${ts}" "${passed}" "${CHECKS_STATE}" "${FAILURES_STATE}" <<'PY'
import json
import os
import sys

report_path, schema_version, timestamp, passed, checks_path, failures_path = sys.argv[1:7]
report = {
    "version": int(schema_version),
    "timestamp": timestamp,
    "passed": passed == "true",
    "checks": json.load(open(checks_path)),
    "failures": json.load(open(failures_path)),
}
with open(report_path, "w", encoding="utf-8") as fh:
    json.dump(report, fh, indent=2)
    fh.write("\n")
os.chmod(report_path, 0o644)
PY
}

main() {
  set +e
  check_arch
  check_kvm
  check_cgroup_v2
  check_systemd
  check_glibc
  check_kernel_nbd
  check_hugetlbfs
  check_resources
  check_port 22 "${ALLOWED_PORT_22_UNITS}" "port_22" "SSH port 22"
  check_port 80 "${ALLOWED_PORT_80_UNITS}" "port_80" "HTTP port 80"
  check_port 443 "${ALLOWED_PORT_443_UNITS}" "port_443" "HTTPS port 443"
  check_dns
  check_egress
  set -e

  local overall_passed
  overall_passed="$(python3 - "${FAILURES_STATE}" <<'PY'
import json
import sys

failures = json.load(open(sys.argv[1]))
print("true" if not failures else "false")
PY
)"
  write_report "${overall_passed}"
  if [[ "${overall_passed}" == "true" ]]; then
    exit 0
  fi
  exit 1
}

main "$@"
