# traefik

Static Traefik binary under systemd. **The only process permitted to bind
`0.0.0.0`** (entrypoints 80 and 443).

## Routers

| Name | Rule | Backend | Priority |
|---|---|---|---|
| `e2b-api` | `Host(api.e2b.<d>)` | `127.0.0.1:8080` | 500 |
| `e2b-sandbox` | `HostRegexp(*.e2b.<d>)` | `127.0.0.1:3002` | 100 |
| `kodus-web` | `Host(kodus.<d>)` | `127.0.0.1:3000` | default |
| `kodus-api` | `Host(kodus-api.<d>)` | `127.0.0.1:3001` | default |
| `kodus-webhooks` | `Host(kodus-webhooks.<d>)` | `127.0.0.1:3332` | default |

`Host` is passed through unchanged. `websecure` `respondingTimeouts` are
read/write `0` and idle `24h`. `serversTransport.forwardingTimeouts` uses
`idleConnTimeout=600s` (below client-proxy's 610s) and `responseHeaderTimeout=0`.
`e2b-api` has a 16 MiB request body limit.

## TLS

| `tls_mode` | Behaviour |
|---|---|
| `acme_dns` | Built-in lego DNS-01 (`tls_acme_dns_provider` + credentials in `secrets.env` or `/etc/qops/traefik-acme.env`) |
| `provided` | File provider certs (`tls_cert_path` / `tls_key_path`) |
| `internal_ca` | **Fails explicitly** (M2) |

## Hairpin gate

`https://api.e2b.<d>/health` is probed from a container on the `kodus` Docker
network. That network is created by the **kodus** role, which runs **after**
this role in `site.yml`. When the network is absent the check prints `skipped`
and does not fail. A later `site.yml` run (or `doctor.yml`) exercises the
real hairpin path once Kodus exists.

Implemented in **Task 8** (see `../../../docs/superpowers/specs/2026-08-28-kodus-e2b-selfhost-design.md`, Phase 2).
