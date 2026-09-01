#!/usr/bin/env bash
# Build a dedicated Traefik ACME credentials file from secrets.env.
# Only DNS-01 / lego provider keys are copied. E2B API keys, database
# passwords and the hash seed are never included.
set -euo pipefail

SECRETS_FILE="${1:?secrets file required}"
DEST="${2:?traefik ACME env path required}"

if [[ ! -f "${SECRETS_FILE}" ]]; then
  echo "secrets file missing: ${SECRETS_FILE}" >&2
  exit 1
fi

python3 - "${SECRETS_FILE}" "${DEST}" <<'PY'
import os
import pathlib
import sys
import tempfile

src = pathlib.Path(sys.argv[1])
dest = pathlib.Path(sys.argv[2])

ALLOW_PREFIXES = (
    "ACME_",
    "AWS_",
    "AZURE_",
    "CF_",
    "CLOUDFLARE_",
    "CLOUDNS_",
    "DIGITALOCEAN_",
    "DNSSIMPLE_",
    "DO_",
    "GANDI_",
    "GCE_",
    "GCLOUD_",
    "GODADDY_",
    "GOOGLE_",
    "HETZNER_",
    "LEGO_",
    "LINODE_",
    "NAMEDOTCOM_",
    "NS1_",
    "OVH_",
    "POWERDNS_",
    "RFC2136_",
    "ROUTE53_",
    "VULTR_",
)
DENY_KEYS = {
    "E2B_API_KEY",
    "E2B_POSTGRES_PASSWORD",
    "E2B_CLICKHOUSE_PASSWORD",
    "E2B_CLICKHOUSE_USERNAME",
    "SANDBOX_ACCESS_TOKEN_HASH_SEED",
    "KODUS_LICENSE_KEY",
}
DENY_PREFIXES = ("E2B_", "SANDBOX_", "KODUS_")

selected = []
for raw in src.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, _, value = line.partition("=")
    if key in DENY_KEYS or key.startswith(DENY_PREFIXES):
        continue
    if key.startswith(ALLOW_PREFIXES):
        selected.append(f"{key}={value}\n")

dest.parent.mkdir(parents=True, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=dest.name + ".", dir=str(dest.parent))
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write("".join(selected))
    os.replace(tmp, dest)
    os.chmod(dest, 0o600)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
echo installed
