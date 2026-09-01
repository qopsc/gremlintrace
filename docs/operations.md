# Operations runbooks

**Status:** Runbooks reflect implemented roles and scripts. **None have been validated on a live cluster** except where noted as covered by local bats tests or (when CI secrets exist) the installer-matrix workflow.

## General diagnostics

```bash
./bootstrap.sh --playbook doctor --limit <host>
cat /etc/qops/doctor.json
journalctl -u e2b-orchestrator -u e2b-api -u traefik -f
```

---

## Sandbox stuck

**Recognise:** PR reviews hang; worker logs show sandbox create/start errors; `qops-doctor` `e2b_smoke` fails; E2B API `/health` returns 503 or orchestrator `/health` unhealthy.

**Confirm:**

```bash
systemctl status e2b-orchestrator e2b-api e2b-client-proxy
curl -sS http://127.0.0.1:5008/health
curl -sS http://127.0.0.1:8080/health
journalctl -u e2b-orchestrator --since "30 min ago" | tail -100
```

Check for `max-starting-instances-per-node=3` throttling (compile-time upstream limit; Phase 0 should measure queueing).

**Do:**

1. If orchestrator is wedged, set `FORCE_STOP=true` **and** create the interface marker `/orchestrator/force-stop` (empty, mode `0600`, root-owned) via `/usr/local/lib/qops/e2b-set-force-stop.sh /etc/qops/e2b/orchestrator.env true`, then `systemctl restart e2b-orchestrator`. The env var is parsed once at process start; the marker is what a *running* patched orchestrator consults at SIGTERM. Remove the marker after a successful stop so a later ordinary stop still drains. Without force-stop, drain can take up to ~35 min (or SIGKILL at `TimeoutStopSec=180`). Live FORCE_STOP behaviour is **unverified**.
2. Inspect `/sys/fs/cgroup/e2b/`, `ip link show type veth`, `/run/netns/`.
3. Run `/usr/local/lib/qops/e2b-cleanup-runtime.sh` (installed by `e2b_services`) if netns/veth remain after stop.
4. Re-run `doctor.yml`. If templates are corrupt, use `upgrade.yml` with `e2b_templates_force` only after understanding template alias state.

---

## Hugepages exhausted

**Recognise:** Firecracker start failures mentioning hugepages; `qops-doctor` `hugepages` check shows `HugePages_Free` near zero.

**Confirm:**

```bash
grep -i huge /proc/meminfo
systemctl status e2b-hugepages.service
cat /usr/local/lib/qops/e2b-allocate-hugepages.sh  # installed path
```

**Do:**

1. Ensure `e2b-hugepages.service` ran before Docker (`Before=docker.service`).
2. Reduce concurrent sandboxes (`e2b_max_concurrent_sandboxes`) or add RAM.
3. Reboot only after planning — hugepage allocation is sensitive to fragmentation (`e2b_host` README notes re-run determinism on live hosts is unverified).

---

## nbd exhaustion

**Recognise:** Orchestrator errors opening `/dev/nbd*`; doctor `nbd_in_use` high; `ls /sys/block/nbd*/size` shows many non-zero sizes after sandbox kills.

**Confirm:**

```bash
lsmod | grep nbd
grep . /sys/block/nbd*/size | grep -v ':0$'
journalctl -u e2b-orchestrator | grep -i nbd
```

**Do:**

1. Verify `nbd` module loaded (`modprobe nbd nbds_max=4096` per `e2b_host` role).
2. Stop stray sandboxes; restart orchestrator with `FORCE_STOP=true` during maintenance.
3. After kernel upgrade, confirm `nbd.ko` exists for the **running** kernel (`doctor` `nbd_ko_newest_kernel`).

---

## RabbitMQ `QueueBind 404`

**Recognise:** Worker logs contain `QueueBind` 404 or PRECONDITION_FAILED; reviews never dequeue.

**Confirm:**

```bash
docker exec -it $(docker ps -qf name=rabbitmq) rabbitmqctl list_queues name messages consumers
docker exec -it $(docker ps -qf name=rabbitmq) rabbitmqctl list_bindings
```

**Do:**

1. Restart Kodus worker after RabbitMQ is healthy: `docker compose -f /opt/kodus-installer/docker-compose.yml restart worker` (exact service name per upstream compose).
2. If definitions are corrupt, restore from latest `/var/backups/qops/latest/rabbitmq-definitions.json` (manual import — `restore.yml` is M2).
3. Re-run upstream `scripts/install.sh` only via the `kodus` role digest gate (do not hand-edit queues).

---

## Webhook silent failure

**Recognise:** Git provider shows failed/redelivered webhooks; no Kodus activity; `doctor` `webhook_reachability` skipped or failed.

**Confirm:**

- Off-host: `curl -fsS https://kodus-webhooks.<d>/health`
- Set `doctor_webhook_external_probe_cmd` to run that curl from outside the host.
- Check Traefik access logs and Kodus webhooks container logs.
- Verify DNS points to this host and TLS cert covers `kodus-webhooks.<d>`.

**Do:**

1. Fix DNS/TLS/firewall (only 80/443 public on host).
2. For NAT-only sites, document Cloudflare Tunnel or reverse proxy (not wired in CI — see `ci/matrix/synthetic-github-webhook.sh` for what synthetic POST proves).
3. Confirm webhook URL in git provider matches `API_*_CODE_MANAGEMENT_WEBHOOK` in `.env` (dedicated webhooks host).

---

## Docker Hub rate limits during template builds

**Recognise:** `e2b_templates` role fails pulling `e2bdev/base`; build logs show 429/toomanyrequests.

**Confirm:** Template build output in Ansible log; `docker pull e2bdev/base` on the host.

**Do:**

1. Mirror `e2bdev/base` to a customer registry and set the template base image variable in `e2b/templates` build config.
2. Retry after rate-limit window; schedule template builds off-peak.
3. Re-run `upgrade.yml` with template force only when pins changed (avoid unnecessary rebuilds).

---

## Redis restart orphaning running-sandbox catalog

**Recognise:** API thinks sandboxes are running after Redis flush/restart; stale entries block concurrency.

**Confirm:**

```bash
docker compose -p e2b-data -f /etc/qops/e2b-data/docker-compose.yml exec redis redis-cli INFO keyspace
```

Compare with orchestrator sandbox list / API sandboxes endpoint.

**Do:**

1. Prefer controlled restarts via `upgrade.yml` (orchestrator stopped with `FORCE_STOP`).
2. If Redis was restarted uncleanly, restart `e2b-api` and `e2b-orchestrator` after Redis is healthy.
3. Kill orphaned sandboxes via E2B API or orchestrator drain; re-run `doctor.yml`.

---

## E2B API key rotation

**Recognise:** Need to rotate `E2B_API_KEY` / team API key; compromise response.

**Confirm:** Key in `/etc/qops/secrets.env` and Kodus `.env` `API_E2B_KEY`; Postgres `team_api_keys` stores hashes only.

**Do:**

1. **Do not** re-run `e2b-seed` — it deletes the team’s envs/snapshots on re-run (gated on empty team row only).
2. Rotation requires upstream E2B admin procedure or DB-level key replacement (not automated in M1). Plan maintenance: stop workers, update key in `secrets.env` and Kodus `.env`, restart `e2b-api` and Kodus worker.
3. Document as operational gap until a supported rotation playbook exists.

---

## Upgrade procedure

See `docs/install.md`. Summary:

```bash
# versions.yml bumped on controller
./bootstrap.sh --playbook upgrade --limit <host>
```

`upgrade.yml` runs `qops-backup`, `qops-backup-verify`, asserts `e2b-assert-dist-pair.sh`, compares pins via `e2b-compare-upgrade-pins.py`, rebuilds templates only when envd/kernel/Firecracker change.

---

## Backup procedure

M1 installs `qops-backup` timer via the `backup` role in `site.yml` (not the placeholder `backup.yml` playbook).

**On demand:**

```bash
sudo qops-backup
sudo qops-backup-verify /var/backups/qops/latest
```

**Contents:** Kodus Postgres, E2B Postgres, Mongo archive, RabbitMQ definitions, `/etc/qops` tarball. Retention: `backup_retention_days` (default 7). Off-box `backup_target: s3|rsync` is M2.

---

## Garbage collection (paused snapshots)

Timer: `qops-e2b-gc` (default 03:30 UTC).

**On demand:**

```bash
sudo qops-e2b-gc --dry-run
sudo qops-e2b-gc
```

Deletes `<store>/<buildID>/` dirs not referenced as live `env_build_assignments.build_id` (assignments whose `env_id` is a live template or a live snapshot) and older than `e2b_snapshot_retention_hours` (default 168h). `snapshots.id` is a row UUID and is **not** a storage key. Prunes stale Local-registry `templateId:buildId` images. Holds `LOCK TABLE env_builds, env_build_assignments, snapshots IN SHARE ROW EXCLUSIVE MODE` across query-and-delete so INSERT waits. Fails closed if the DB query or lock is unreachable.

Header-chain walking (parent build IDs in on-disk headers) is an **unverified M1 limitation** — see `docs/spike-notes.md`. Live GC against Postgres is **unverified**.

---

## Uninstall

```bash
./bootstrap.sh --playbook uninstall --limit <host> \
  -e qops_uninstall_confirm=true \
  -e qops_uninstall_destroy_data=false
```

Uses `qops-uninstall` helper; destroys data only when `qops_uninstall_destroy_data=true`.
