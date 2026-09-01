# backup

M1 operational jobs: `qops-backup` (+ timer), `qops-e2b-gc` (+ timer), and the
`qops-uninstall` helper used by `uninstall.yml`.

This role implements the M1 operational jobs described in the design spec.

`qops-e2b-gc` lives in this role (not `e2b_services`) because it is a
data-lifecycle job with the same shape as backups: a root oneshot, a calendar
timer, retention, and deliberate deletion of customer data. Service bootstrap
does not need it.

## Layout

| Path | Purpose |
|---|---|
| `/usr/local/bin/qops-backup` | M1 backup entrypoint |
| `/usr/local/bin/qops-backup-verify` | Fail closed on empty/corrupt bundles |
| `/usr/local/bin/qops-e2b-gc` | Wrapper; python lives at `/usr/local/lib/qops/qops-e2b-gc` |
| `/usr/local/bin/qops-uninstall` | Confirmation-gated uninstall helper |
| `/var/backups/qops/<UTC-stamp>/` | One bundle per run |
| `/var/backups/qops/latest` | Symlink written **after** verify succeeds |
| `qops-backup.timer` | Calendar: `backup_timer_on_calendar` (default 02:00 UTC) |
| `qops-e2b-gc.timer` | Calendar: `backup_gc_timer_on_calendar` (default 03:30 UTC) |

## M1 backup contents

Each bundle contains:

- `kodus-postgres.sql.gz` — plain `pg_dump` of Kodus Postgres (`:5432`)
- `e2b-postgres.sql.gz` — plain `pg_dump` of E2B Postgres (`127.0.0.1:5433`, db `e2b`)
- `mongo.archive.gz` — `mongodump --archive --gzip`
- `rabbitmq-definitions.json` — `rabbitmqctl export_definitions`
- `etc-qops.tar.gz` — `/etc/qops` (secrets, env files, generated Kodus secrets)
- `MANIFEST.json`, `SHA256SUMS`

`upgrade.yml` runs `qops-backup` and then **independently** runs
`qops-backup-verify` on `/var/backups/qops/latest`. A script that exits 0
without producing a usable dump still fails the playbook.

## Deferred to M2

- Template-store rsync/restic (Local/NFS) and bucket-native backup (S3)
- ClickHouse / Redis dumps
- Off-box `backup_target: s3|rsync` (variable exists; unused in M1)
- `backup.yml` / `restore.yml` playbooks and the weekly restore drill

## GC safety

`qops-e2b-gc` deletes `<store>/<buildID>/` directories that are **not** in live
`env_builds` / `snapshots` rows **and** older than `e2b_snapshot_retention_hours`
(default 168). It also prunes Local-registry `templateId:buildId` images.

It fail-closes when the database query is unreachable or omits the sentinel
`__QOPS_E2B_GC_QUERY_OK__` (an empty successful result is not treated as an
error). `--dry-run` logs candidates and unlinks nothing. Before each delete it
re-queries so a build created during the run is kept.
