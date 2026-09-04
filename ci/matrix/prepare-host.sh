#!/usr/bin/env bash
# Host prep for the installer-matrix leg: modules, sysctl, DNS, TLS, probe targets.
#
# Isolation probe host-proof listeners (after site.yml):
#   127.0.0.1:5008/health  — e2b-orchestrator
#   10.255.0.1:80/         — Traefik on 0.0.0.0:80 once 10.255.0.1 is on lo
# This script assigns 10.255.0.1/32 on lo and starts a dummy HTTP listener on
# 10.255.0.1:80 until run-bootstrap.sh stops it so Traefik can bind :80.
set -euo pipefail

DOMAIN="${QOPS_CI_DOMAIN:-ci.qops.test}"
TLS_DIR="/etc/qops/ci-tls"
HOSTS_MARKER="# qops-ci-matrix"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DNS_PY="${REPO_ROOT}/ci/matrix/wildcard-dns.py"
LAN_PY="${REPO_ROOT}/ci/matrix/lan-listener.py"
DNS_BIND="127.0.0.54"
DNS_PIDFILE="/run/qops-wildcard-dns.pid"
LAN_PIDFILE="/run/qops-lan-listener.pid"

sudo mkdir -p "${TLS_DIR}" /etc/qops /run

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

# /etc/hosts cannot implement wildcard DNS. A Python responder answers
# *.e2b.<domain> and *.<domain> (including preflight's random label).
sudo sed -i "/${HOSTS_MARKER}/d" /etc/hosts || true
{
  printf '%s %s %s\n' "${HOST_IP}" "${DOMAIN}" "${HOSTS_MARKER}"
} | sudo tee -a /etc/hosts >/dev/null

if ! ip -4 addr show lo | grep -q "inet ${LAN_IP}/"; then
  sudo ip addr add "${LAN_IP}/32" dev lo
fi

if [[ -f "${DNS_PIDFILE}" ]] && kill -0 "$(cat "${DNS_PIDFILE}")" 2>/dev/null; then
  echo "wildcard-dns already running pid=$(cat "${DNS_PIDFILE}")"
else
  sudo bash -c '
    exec python3 "$0" \
      --bind "$1" \
      --port 53 \
      --address "$2" \
      --zone "$3" \
      --zone "e2b.$3" \
      --pidfile "$4" \
      >/tmp/qops-wildcard-dns.log 2>&1
  ' "${DNS_PY}" "${DNS_BIND}" "${HOST_IP}" "${DOMAIN}" "${DNS_PIDFILE}" &
  # python is started via sudo in background; write pid from the helper.
  sleep 0.3
fi

sudo mkdir -p /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/qops-ci.conf >/dev/null <<EOF
[Resolve]
DNS=${DNS_BIND}
Domains=~${DOMAIN}
EOF
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  sudo systemctl restart systemd-resolved
fi
# Also point the stub resolver at our daemon for this zone when resolvectl exists.
if command -v resolvectl >/dev/null 2>&1; then
  sudo resolvectl dns lo "${DNS_BIND}" 2>/dev/null || true
  sudo resolvectl domain lo "~${DOMAIN}" 2>/dev/null || true
fi

if [[ -f "${LAN_PIDFILE}" ]] && kill -0 "$(cat "${LAN_PIDFILE}")" 2>/dev/null; then
  echo "lan-listener already running pid=$(cat "${LAN_PIDFILE}")"
else
  sudo bash -c '
    exec python3 "$0" --bind "$1" --port 80 --pidfile "$2" \
      >/tmp/qops-lan-listener.log 2>&1
  ' "${LAN_PY}" "${LAN_IP}" "${LAN_PIDFILE}" &
  sleep 0.3
fi

sudo modprobe kvm 2>/dev/null || true
sudo modprobe kvm_intel 2>/dev/null || sudo modprobe kvm_amd 2>/dev/null || true
sudo modprobe nbd nbds_max=64 2>/dev/null || true
echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward >/dev/null

printf 'prepare-host: domain=%s public_ip=%s host_ip=%s lan_ip=%s dns=%s:%s\n' \
  "${DOMAIN}" "${PUBLIC_IP}" "${HOST_IP}" "${LAN_IP}" "${DNS_BIND}" "53"
printf 'prepare-host: host-proof ports: 127.0.0.1:5008 (orchestrator after site.yml), %s:80 (dummy now; Traefik after site.yml)\n' \
  "${LAN_IP}"
