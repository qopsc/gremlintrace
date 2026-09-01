# kodus

Clone `kodustech/kodus-installer` at `versions.yml:kodus_installer_ref`, render `.env`
and `docker-compose.override.yml`, start the stack without forking Kodus.

## Contract

| Item | Value |
|---|---|
| Installer checkout | `/opt/kodus-installer` (`kodus_install_dir`) |
| Env file | `/opt/kodus-installer/.env` mode `0600` |
| Persisted secrets | `/etc/qops/kodus/generated-secrets.env` mode `0600` |
| Compose override | `/opt/kodus-installer/docker-compose.override.yml` |
| Callback URL summary | `/etc/qops/kodus/callback-urls.txt` |
| External Docker networks | `shared-network`, `monitoring-network`, `kodus-backend-services`, plus `kodus` for the Traefik hairpin probe |
| Template aliases | `API_E2B_TEMPLATE_ID=kodus-sandbox`, `API_E2B_TEMPLATE_GRAPH_ID=kodus-sandbox-graph` |
| E2B domain | `E2B_DOMAIN=e2b.<qops_domain>` |
| `IMAGE_TAG` | `versions.yml:kodus_image_tag` (never `latest`) |
| `E2B_PROXY_HOST` | unset |
| Bind policy | every published Compose port rebound to `127.0.0.1` |

`scripts/generate-secrets.sh` runs only when the persist file is missing or incomplete.
Re-runs merge the persisted values back into `.env` and do not invoke the generator.

`scripts/install.sh` is gated on stack health. If web `:3000/health`, api `:3001/health`,
and webhooks `:3332/health` all return HTTP 200, install.sh is not called (it always
passes `--force-recreate`).

Operator callback URLs printed at the end of the role:

- GitHub App callback: `https://kodus.<d>/api/auth/callback/github`
- GitHub App setup: `https://kodus.<d>/setup/github`
- GitHub App webhook: `https://kodus-webhooks.<d>/github/webhook`
- GitHub OAuth callback: `https://kodus.<d>/api/auth/callback/github`
- MCP OAuth redirect: `https://kodus.<d>/setup/mcp/oauth`

LLM keys: `kodus_openai_api_key` / `kodus_openai_force_base_url`, or `API_OPEN_AI_API_KEY`
in `/etc/qops/secrets.env`, or `kodus_env_overrides`. Anthropic keys use the same
`API_OPEN_AI_API_KEY` slot.
