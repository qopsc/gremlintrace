# kodus

Clone `kodustech/kodus-installer` at `versions.yml:kodus_installer_ref`, render `.env`
and `docker-compose.override.yml`, start the stack without forking Kodus.

## Contract

| Item | Value |
|---|---|
| Installer checkout | `/opt/kodus-installer` (`kodus_install_dir`) |
| Env file | `/opt/kodus-installer/.env` mode `0600` |
| Persisted secrets | `/etc/qops/kodus/generated-secrets.env` mode `0600` |
| Install digest | `/etc/qops/kodus/install.digest` (ref + `.env` + effective compose) |
| Compose override | `/opt/kodus-installer/docker-compose.override.yml` |
| Callback URL summary | `/etc/qops/kodus/callback-urls.txt` |
| External Docker networks | `shared-network`, `monitoring-network`, `kodus-backend-services`, plus `kodus` for the Traefik hairpin probe |
| Template aliases | `API_E2B_TEMPLATE_ID=kodus-sandbox`, `API_E2B_TEMPLATE_GRAPH_ID=kodus-sandbox-graph` |
| `IMAGE_TAG` | `versions.yml:kodus_image_tag` (never `latest`) |
| `E2B_PROXY_HOST` | unset |
| Bind policy | every published Compose port rebound to `127.0.0.1` via `ports: !override` |

`ports: !override` requires **Docker Compose v2.24.0** (Compose Specification 3.24). Without the tag, Compose *adds* a `127.0.0.1` mapping beside upstream's `0.0.0.0` mapping. The role runs `compose-merge-ports.py check` against the merged model and fails if any effective published port lacks `127.0.0.1`.

`scripts/generate-secrets.sh` runs only when the persist file is missing or incomplete.

`scripts/install.sh` is gated on a desired-state digest (installer ref, rendered `.env`, effective compose) **and** running containers. A matching digest with containers present skips `install.sh` even if health is down (health waits then fail). The digest is written only after a successful install.

Webhook URLs are validated against the dedicated `kodus-webhooks.<d>` host. Upstream `scripts/doctor.sh` is then run; failure is tolerated **only** when the complete ERROR set is exactly the known `host must match WEB_HOSTNAME_API` diagnostics.

When `kodus_extra_hosts_hairpin` is true, `.env` sets `E2B_API_URL=https://api.e2b.<d>` and `E2B_SANDBOX_URL=https://sandbox.e2b.<d>`, and compose `extra_hosts` maps both names to `host-gateway`.

Operator callback URLs printed at the end of the role:

- GitHub App callback: `https://kodus.<d>/api/auth/callback/github`
- GitHub App setup: `https://kodus.<d>/setup/github`
- GitHub App webhook: `https://kodus-webhooks.<d>/github/webhook`
- GitHub OAuth callback: `https://kodus.<d>/api/auth/callback/github`
- MCP OAuth redirect: `https://kodus.<d>/setup/mcp/oauth`
