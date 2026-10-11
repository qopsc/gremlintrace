#!/usr/bin/env bash
# Write the dedicated Traefik ACME credentials file from a JSON object on stdin.
#
#   printf '%s' '{"PORKBUN_API_KEY":"...","PORKBUN_SECRET_API_KEY":"..."}' \
#     | install-traefik-acme-env.sh DEST PROVIDER [EXTRA_KEYS]
#
# The object is tls_acme_dns_credentials, decrypted on the control machine by
# community.sops from host_vars/<host>/*.sops.yml. Only keys the configured lego
# provider uses (plus EXTRA_KEYS, comma separated) are accepted; anything else
# is refused so an E2B/database secret can never land in Traefik's environment.
# Values never appear on argv or in error output. Prints "installed" when the
# file content changed and "unchanged" otherwise (Ansible changed_when).
#
#   install-traefik-acme-env.sh --check-keys PROVIDER EXTRA_KEYS KEY1,KEY2
#
# validates key names only (no values, nothing on stdin) and prints "ok" or a
# readable list of the rejected names, so Ansible can run it without no_log
# before the secret-carrying install.
set -euo pipefail

MODE=install
if [[ "${1:-}" == "--check-keys" ]]; then
  MODE=check
  shift
  PROVIDER="${1:?ACME DNS provider required}"
  EXTRA_KEYS="${2:-}"
  KEY_LIST="${3:-}"
  exec 3</dev/null
  set -- "${KEY_LIST}" "${PROVIDER}" "${EXTRA_KEYS}"
else
  DEST="${1:?traefik ACME env path required}"
  PROVIDER="${2:?ACME DNS provider required}"
  EXTRA_KEYS="${3:-}"
  # The Python source arrives on stdin (heredoc), so the credentials pipe is
  # handed over on fd 3.
  exec 3<&0
  set -- "${DEST}" "${PROVIDER}" "${EXTRA_KEYS}"
fi
python3 - "${MODE}" "$@" <<'PY'
import json
import os
import pathlib
import sys
import tempfile

mode = sys.argv.pop(1)
dest = pathlib.Path(sys.argv[1])

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
    "porkbun": {"PORKBUN_API_KEY", "PORKBUN_SECRET_API_KEY"},
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

provider = sys.argv[2].strip().lower()
keys = set(PROVIDER_KEYS.get(provider, set()))
for key in sys.argv[3].split(",") if sys.argv[3] else []:
    key = key.strip()
    if key:
        if not key.replace("_", "").isalnum() or not key.isupper():
            raise SystemExit(f"invalid traefik ACME environment key: {key}")
        keys.add(key)
if not keys:
    raise SystemExit(
        f"unsupported ACME DNS provider {provider!r}; configure traefik_acme_env_keys explicitly"
    )

if mode == "check":
    # argv[1] is the comma-separated key names; values never reach this mode.
    credentials = {k.strip(): "" for k in sys.argv[1].split(",") if k.strip()}
else:
    try:
        with os.fdopen(3, "r", encoding="utf-8") as credentials_in:
            credentials = json.load(credentials_in)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"tls_acme_dns_credentials is not a JSON object: {exc.msg}") from None
if not isinstance(credentials, dict):
    raise SystemExit("tls_acme_dns_credentials must be a mapping of ENV_NAME to value")

expected = ", ".join(sorted(keys))
unknown = sorted(k for k in credentials if k not in keys)
if unknown:
    raise SystemExit(
        f"tls_acme_dns_credentials has keys the lego provider {provider!r} does not use: "
        f"{', '.join(unknown)}. Allowed: {expected} (add others via traefik_acme_env_keys). "
        "Refusing to write Traefik's environment."
    )
if not credentials:
    raise SystemExit(
        f"no ACME DNS credentials for provider {provider!r}: set tls_acme_dns_credentials "
        f"(one or more of {expected}) in the host's sops-encrypted host_vars"
    )
if mode == "check":
    print("ok")
    raise SystemExit(0)

lines = []
for key in sorted(credentials):
    value = credentials[key]
    if not isinstance(value, str) or "\n" in value or "\r" in value:
        raise SystemExit(f"tls_acme_dns_credentials.{key} must be a single-line string")
    lines.append(f"{key}={value}\n")
content = "".join(lines)

if dest.is_file() and dest.read_text(encoding="utf-8") == content:
    os.chmod(dest, 0o600)
    print("unchanged")
    raise SystemExit(0)

dest.parent.mkdir(parents=True, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=dest.name + ".", dir=str(dest.parent))
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(content)
    os.replace(tmp, dest)
    os.chmod(dest, 0o600)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
print("installed")
PY
