#!/usr/bin/env bash
# Host prep for the installer-matrix leg: modules, sysctl, DNS, TLS, probe targets.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOMAIN="${QOPS_CI_DOMAIN:-ci.qops.test}"
TLS_DIR="/etc/qops/ci-tls"
HOSTS_MARKER="# qops-ci-matrix"

sudo mkdir -p "${TLS_DIR}" /etc/qops

if [[ ! -f "${TLS_DIR}/tls.crt" ]]; then
  sudo openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
    -keyout "${TLS_DIR}/tls.key" \
    -out "${TLS_DIR}/tls.crt" \
    -subj "/CN=*.${DOMAIN}" \
    -addext "subjectAltName=DNS:${DOMAIN},DNS:*.${DOMAIN},DNS:*.e2b.${DOMAIN},DNS:api.e2b.${DOMAIN},DNS:kodus.${DOMAIN},DNS:kodus-api.${DOMAIN},DNS:kodus-webhooks.${DOMAIN}"
  sudo chmod 0644 "${TLS_DIR}/tls.crt"
  sudo chmod 0600 "${TLS_DIR}/tls.key"
fi

PUBLIC_IP="$(curl -fsS --max-time 10 https://api.ipify.org || true)"
if [[ -z "${PUBLIC_IP}" ]]; then
  PUBLIC_IP="$(hostname -I | awk '{print $1}')"
fi
LAN_IP="10.255.0.1"

sudo tee /etc/qops/ci-matrix.env >/dev/null <<EOF
QOPS_CI_DOMAIN=${DOMAIN}
QOPS_CI_PUBLIC_IPV4=${PUBLIC_IP}
QOPS_CI_LAN_IPV4=${LAN_IP}
EOF
sudo chmod 0644 /etc/qops/ci-matrix.env

HOST_IP="$(hostname -I | awk '{print $1}')"
sudo sed -i "/${HOSTS_MARKER}/d" /etc/hosts || true
{
  printf '%s %s\n' "${HOST_IP}" "${DOMAIN}"
  printf '%s api.e2b.%s\n' "${HOST_IP}" "${DOMAIN}"
  printf '%s preflight-check.e2b.%s\n' "${HOST_IP}" "${DOMAIN}"
  printf '%s kodus.%s\n' "${HOST_IP}" "${DOMAIN}"
  printf '%s kodus-api.%s\n' "${HOST_IP}" "${DOMAIN}"
  printf '%s kodus-webhooks.%s\n' "${HOST_IP}" "${DOMAIN}"
  printf '%s sandbox.e2b.%s %s\n' "${HOST_IP}" "${DOMAIN}" "${HOSTS_MARKER}"
} | sudo tee -a /etc/hosts >/dev/null

sudo modprobe kvm 2>/dev/null || true
sudo modprobe kvm_intel 2>/dev/null || sudo modprobe kvm_amd 2>/dev/null || true
sudo modprobe nbd nbds_max=64 2>/dev/null || true
echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward >/dev/null

printf 'prepare-host: domain=%s public_ip=%s host_ip=%s\n' "${DOMAIN}" "${PUBLIC_IP}" "${HOST_IP}"
