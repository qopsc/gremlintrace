# traefik

Static Traefik binary under systemd. Traefik is the **only listener whose
80/443 are reachable from the network** (the only process we *intend* to
publish). E2B Go services hardcode `0.0.0.0` and are dropped by the host
nftables input chain; see `ansible/roles/e2b_services` and
`docs/architecture.md`.

Executables (`/usr/local/bin`), configs (`/etc/traefik`), and the shared
cache (`/var/cache/qops`) stay **root-owned**. Only `/var/lib/traefik` is
writable by the `traefik` user, so the network-facing account cannot replace
binaries or poison archives that root later installs, and the role does not
fight `e2b_services` over `/var/cache/qops` on a second run.

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
`idleConnTimeout=600s` (must stay **< 610s**, client-proxy's idle) and
`responseHeaderTimeout=0`. Those bounds are asserted at render time.

There is **no buffering middleware**. Buffering breaks long streaming
`commands.run` calls. Traefik therefore streams and admits `api.e2b` bodies
of any size (the documented minimum is 16 MiB; a smaller override fails the
assert).

## TLS

| `tls_mode` | Behaviour |
|---|---|
| `acme_dns` | Built-in lego DNS-01. Only credentials for the configured `tls_acme_dns_provider` (plus explicit `traefik_acme_env_keys`) are copied to `/etc/qops/traefik-acme.env` (0600, root) — **not** the whole `/etc/qops/secrets.env`. |
| `provided` | Source cert/key are stat'd, then installed as Traefik-owned copies under `/var/lib/traefik/tls/` and checked readable as the Traefik user. |
| `internal_ca` | **Fails explicitly** (M2) |

## Hairpin gate (ordering)

`site.yml` order: first play `… → e2b_templates → traefik → kodus → hairpin (required)`; second play `backup → doctor`.

The traefik role runs **before** Kodus creates the `kodus` Docker network.
During that first-install pass `traefik_hairpin_required` is false: if the
network is missing the check prints `skipped` and the role continues.

The **real gate** runs after the kodus role (`site.yml` imports
`tasks_from: hairpin.yml` with `traefik_hairpin_required=true`) and again
from `doctor.yml`. That invocation retries for TLS readiness and requires
an actual HTTP 200 from `https://api.e2b.<d>/health` inside a container on
the `kodus` network. Nonempty output without HTTP 200 is a failure.

Implemented in **Task 8** (see `../../../docs/superpowers/specs/2026-08-28-kodus-e2b-selfhost-design.md`, Phase 2).
