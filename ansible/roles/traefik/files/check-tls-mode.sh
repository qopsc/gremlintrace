#!/usr/bin/env bash
# M1 accepts acme_dns and provided only. internal_ca is M2.
set -euo pipefail

MODE="${1:-}"

case "${MODE}" in
  acme_dns | provided)
    echo ok
    ;;
  internal_ca)
    echo "tls_mode=internal_ca is M2 and is not implemented; use acme_dns or provided" >&2
    exit 1
    ;;
  *)
    echo "unsupported tls_mode=${MODE}; M1 supports acme_dns or provided" >&2
    exit 1
    ;;
esac
