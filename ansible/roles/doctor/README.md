# doctor

Installs `/usr/local/bin/qops-doctor` and runs it. The script reports **every**
failure, then exits non-zero.

## Exit contract

| Exit | Meaning |
|---|---|
| 0 | Every non-skipped check passed |
| 1 | One or more checks failed |

JSON report: `/etc/qops/doctor.json` (same shape as preflight: `version`, `timestamp`,
`passed`, `checks[]`, `failures[]`). Skipped checks set `skipped`/`unverified` and are
**not** counted as passes or added to `failures`.

## Checks

| id | What |
|---|---|
| `preflight` | Re-runs `run-preflight.sh`; malformed/truncated/wrong-schema reports fail this check and the rest still run |
| `unit_*` | systemd `is-active` |
| `hugepages` | Reports `HugePages_Free`; fails if total is 0 |
| `nbd_in_use` | Counts nbd devices with nonzero size |
| `nbd_ko_newest_kernel` | `nbd.ko` exists for **every flavor** of the newest installed kernel version (rc < release) |
| `disk_usage` | `df` on `/var/lib/e2b` and `/orchestrator` |
| `template_store` | `du` of `/var/lib/e2b/storage` |
| `kodus_*_health` | HTTP 200 on loopback health URLs |
| `rabbitmq_queues` | `rabbitmqctl list_queues` |
| `e2b_smoke` | Create `kodus-sandbox`, `echo ok`, kill |
| `isolation_probe` | Distinct public vs LAN targets; host-side listener proof; sandbox deny of `:5008` and LAN; npm allow; `--noproxy '*'` |
| `webhook_reachability` | External probe command (`doctor_webhook_external_probe_cmd`) for `doctor_webhook_url`; missing configuration fails closed |
| `worker_fallback` | Worker logs must not contain `falling back to default` |

Set `qops_public_ipv4` (globally routable) and `qops_lan_ipv4` (RFC1918, distinct). Empty or equal targets fail the isolation probe. Set `doctor_webhook_external_probe_cmd` to a command that probes `doctor_webhook_url` from outside this host; preflight reports a missing command before install and `qops-doctor` fails closed if it is absent.

`doctor.yml` still runs the Traefik hairpin gate in play tasks after this role.
