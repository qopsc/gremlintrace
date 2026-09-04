#!/usr/bin/env bash
# Build a dedicated Traefik ACME credentials file from secrets.env.
# Only DNS-01 / lego provider keys are copied. E2B API keys, database
# passwords and the hash seed are never included.
set -euo pipefail

SECRETS_FILE="${1:?secrets file required}"
DEST="${2:?traefik ACME env path required}"
PROVIDER="${3:?ACME DNS provider required}"
EXTRA_KEYS="${4:-}"

if [[ ! -f "${SECRETS_FILE}" ]]; then
  echo "secrets file missing: ${SECRETS_FILE}" >&2
  exit 1
fi

python3 - "${SECRETS_FILE}" "${DEST}" "${PROVIDER}" "${EXTRA_KEYS}" <<'PY'
import os
import pathlib
import sys
import tempfile

src = pathlib.Path(sys.argv[1])
dest = pathlib.Path(sys.argv[2])

PROVIDER_KEYS = {
    "azure": {
        "AZURE_CLIENT_ID", "AZURE_CLIENT_SECRET", "AZURE_TENANT_ID",
        "AZURE_SUBSCRIPTION_ID", "AZURE_RESOURCE_GROUP", "AZURE_ENVIRONMENT",
    },
    "cloudflare": {
        "CF_API_EMAIL", "CF_API_KEY", "CF_DNS_API_TOKEN", "CF_DNS_API_TOKEN_FILE",
        "CLOUDFLARE_API_EMAIL", "CLOUDFLARE_API_KEY", "CLOUDFLARE_DNS_API_TOKEN",
    },
    "digitalocean": {"DO_AUTH_TOKEN"},
    "gandi": {"GANDI_API_KEY", "GANDI_API_TOKEN"},
    "gcloud": {"GCE_PROJECT", "GCE_SERVICE_ACCOUNT", "GCE_SERVICE_ACCOUNT_FILE"},
    "googleclouddns": {"GCE_PROJECT", "GCE_SERVICE_ACCOUNT", "GCE_SERVICE_ACCOUNT_FILE"},
    "godaddy": {"GODADDY_API_KEY", "GODADDY_API_SECRET"},
    "hetzner": {"HETZNER_API_KEY"},
    "linode": {"LINODE_TOKEN"},
    "namecheap": {"NAMECHEAP_API_USER", "NAMECHEAP_API_KEY"},
    "namesilo": {"NAMESILO_API_KEY"},
    "ns1": {"NS1_APIKEY"},
    "ovh": {
        "OVH_ENDPOINT", "OVH_APPLICATION_KEY", "OVH_APPLICATION_SECRET", "OVH_CONSUMER_KEY",
    },
    "powerdns": {"PDNS_API_KEY", "PDNS_API_URL", "POWERDNS_API_KEY", "POWERDNS_API_URL"},
    "rfc2136": {
        "RFC2136_NAMESERVER", "RFC2136_TSIG_KEY", "RFC2136_TSIG_ALGORITHM", "RFC2136_TSIG_SECRET",
    },
    "route53": {
        "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_REGION",
        "AWS_DEFAULT_REGION", "AWS_HOSTED_ZONE_ID", "AWS_PROFILE", "AWS_ASSUME_ROLE_ARN",
        "AWS_ASSUME_ROLE_EXTERNAL_ID",
    },
    "vultr": {"VULTR_API_KEY"},
}

provider = sys.argv[3].strip().lower()
keys = set(PROVIDER_KEYS.get(provider, set()))
for key in sys.argv[4].split(",") if sys.argv[4] else []:
    key = key.strip()
    if key:
        if not key.replace("_", "").isalnum() or not key.isupper():
            raise SystemExit(f"invalid traefik ACME environment key: {key}")
        keys.add(key)
if not keys:
    raise SystemExit(
        f"unsupported ACME DNS provider {provider!r}; configure traefik_acme_env_keys explicitly"
    )

selected = []
for raw in src.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, _, value = line.partition("=")
    if key in keys:
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
