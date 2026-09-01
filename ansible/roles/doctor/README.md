# doctor

Installs `/usr/local/bin/qops-doctor` and runs it. The script reports **every**
failure, then exits non-zero.

## Exit contract

| Exit | Meaning |
|---|---|
| 0 | Every check passed |
| 1 | One or more checks failed |

JSON report: `/etc/qops/doctor.json` (same shape as preflight: `version`, `timestamp`,
`passed`, `checks[]`, `failures[]`).

## Checks

| id | What |
|---|---|
| `preflight` | Re-runs `run-preflight.sh` |
| `unit_e2b_orchestrator` `unit_e2b_api` `unit_e2b_client_proxy` `unit_traefik` | systemd `is-active` |
| `hugepages` | Reports `HugePages_Free`; fails if total is 0 |
| `nbd_in_use` | Counts nbd devices with nonzero size |
| `nbd_ko_newest_kernel` | `nbd.ko` exists for the **newest installed** kernel under `/lib/modules` |
| `disk_usage` | `df` on `/var/lib/e2b` and `/orchestrator` |
| `template_store` | `du` of `/var/lib/e2b/storage` |
| `kodus_web_health` `kodus_api_health` `kodus_webhooks_health` | HTTP 200 on loopback health URLs |
| `rabbitmq_queues` | `rabbitmqctl list_queues` |
| `e2b_smoke` | Create `kodus-sandbox`, `echo ok`, kill |
| `isolation_probe` | Inside the sandbox: host `:5008/health` blocked, `registry.npmjs.org` ok, LAN HTTP blocked. Inconclusive (curl missing, DNS failure) is a failure |
| `webhook_reachability` | `https://kodus-webhooks.<d>/health` |
| `worker_fallback` | Worker logs must not contain `falling back to default` |

`doctor.yml` still runs the Traefik hairpin gate (`hairpin.yml`, required) before this
role's tasks in Ansible order (`roles` then `tasks` — hairpin is in `tasks`).
