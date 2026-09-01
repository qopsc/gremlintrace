#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  VERIFY="${REPO_ROOT}/ansible/roles/backup/files/qops-backup-verify"
  UPGRADE="${REPO_ROOT}/ansible/playbooks/upgrade.yml"
  RENDER="${REPO_ROOT}/tests/fixtures/render-template.sh"
}

make_bundle() {
  local dest="$1"
  mkdir -p "${dest}"
  printf '%s\n' '-- PostgreSQL database dump' 'SET statement_timeout = 0;' \
    | gzip -c >"${dest}/kodus-postgres.sql.gz"
  printf '%s\n' '-- PostgreSQL database dump' 'SET statement_timeout = 0;' \
    | gzip -c >"${dest}/e2b-postgres.sql.gz"
  printf 'mongo-archive\n' | gzip -c >"${dest}/mongo.archive.gz"
  printf '{ "vhosts": [] }\n' >"${dest}/rabbitmq-definitions.json"
  qops="${BATS_TMPDIR}/etc/qops"
  mkdir -p "${qops}"
  printf 'E2B_API_KEY=e2b\n' >"${qops}/secrets.env"
  tar -C "${BATS_TMPDIR}/etc" -czf "${dest}/etc-qops.tar.gz" qops
  python3 - "${dest}" <<'PY'
import hashlib, json, pathlib, sys
dest = pathlib.Path(sys.argv[1])
names = [
    "kodus-postgres.sql.gz",
    "e2b-postgres.sql.gz",
    "mongo.archive.gz",
    "rabbitmq-definitions.json",
    "etc-qops.tar.gz",
]
lines = []
for name in names:
    digest = hashlib.sha256((dest / name).read_bytes()).hexdigest()
    lines.append(f"{digest}  {name}")
(dest / "SHA256SUMS").write_text("\n".join(lines) + "\n", encoding="utf-8")
manifest = {"created_at": "2026-01-01T000000Z", "version": 1, "files": names + ["SHA256SUMS", "MANIFEST.json"]}
(dest / "MANIFEST.json").write_text(json.dumps(manifest) + "\n", encoding="utf-8")
PY
}

@test "qops-backup-verify accepts a complete M1 bundle" {
  bundle="${BATS_TMPDIR}/good"
  make_bundle "${bundle}"
  run python3 "${VERIFY}" "${bundle}"
  [ "$status" -eq 0 ]
  [[ "$output" == ok* ]]
}

@test "upgrade.yml precondition rejects an empty backup" {
  bundle="${BATS_TMPDIR}/empty"
  make_bundle "${bundle}"
  : >"${bundle}/kodus-postgres.sql.gz"
  python3 - "${bundle}" <<'PY'
import hashlib, pathlib, sys
dest = pathlib.Path(sys.argv[1])
names = [
    "kodus-postgres.sql.gz",
    "e2b-postgres.sql.gz",
    "mongo.archive.gz",
    "rabbitmq-definitions.json",
    "etc-qops.tar.gz",
]
lines = []
for name in names:
    digest = hashlib.sha256((dest / name).read_bytes()).hexdigest()
    lines.append(f"{digest}  {name}")
(dest / "SHA256SUMS").write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
  run python3 "${VERIFY}" "${bundle}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty"* || "$output" == *"too small"* || "$output" == *"checksum"* ]]
}

@test "upgrade.yml precondition rejects a corrupt postgres dump" {
  bundle="${BATS_TMPDIR}/corrupt"
  make_bundle "${bundle}"
  printf 'not-a-gzip-not-a-gzip-not-a-gzip-not-a-gzip-not-a-gzip\n' \
    >"${bundle}/e2b-postgres.sql.gz"
  python3 - "${bundle}" <<'PY'
import hashlib, pathlib, sys
dest = pathlib.Path(sys.argv[1])
names = [
    "kodus-postgres.sql.gz",
    "e2b-postgres.sql.gz",
    "mongo.archive.gz",
    "rabbitmq-definitions.json",
    "etc-qops.tar.gz",
]
lines = []
for name in names:
    digest = hashlib.sha256((dest / name).read_bytes()).hexdigest()
    lines.append(f"{digest}  {name}")
(dest / "SHA256SUMS").write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
  run python3 "${VERIFY}" "${bundle}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"gzip"* || "$output" == *"PostgreSQL"* || "$output" == *"not a valid"* ]]
}

@test "upgrade.yml calls qops-backup-verify on latest after qops-backup" {
  run python3 - "${UPGRADE}" <<'PY'
import sys, yaml
play = yaml.safe_load(open(sys.argv[1]))[0]
names = [t.get("name", "") for t in play["tasks"]]
backup = next(i for i, n in enumerate(names) if n.startswith("Take an M1 backup"))
verify = next(i for i, n in enumerate(names) if "Verify the backup bundle is usable" in n)
assert backup < verify
verify_task = play["tasks"][verify]
cmd = verify_task["ansible.builtin.command"]["cmd"]
assert "backup_verify_script_path" in cmd
assert "latest" in cmd
print("ok")
PY
  [ "$status" -eq 0 ]
}

@test "systemd-analyze verify accepts backup and GC units" {
  vars="${BATS_TMPDIR}/prod-vars.yml"
  python3 - "${REPO_ROOT}" "${vars}" <<'PY'
import pathlib, sys, yaml
root = pathlib.Path(sys.argv[1])
merged = {}
for path in (root / "versions.yml", root / "ansible/group_vars/all.yml"):
    merged.update(yaml.safe_load(path.read_text()) or {})
for role in (
    "preflight", "common", "host_firewall", "docker", "e2b_host",
    "e2b_datastores", "e2b_services", "e2b_templates", "traefik", "kodus",
    "backup", "doctor",
):
    defaults = root / f"ansible/roles/{role}/defaults/main.yml"
    if defaults.is_file():
        merged.update(yaml.safe_load(defaults.read_text()) or {})
dummy = pathlib.Path(sys.argv[2]).parent / "unit-bins"
dummy.mkdir(parents=True, exist_ok=True)
for name in ("qops-backup", "qops-e2b-gc"):
    link = dummy / name
    if link.exists() or link.is_symlink():
        link.unlink()
    link.symlink_to("/bin/true")
merged["backup_script_path"] = str(dummy / "qops-backup")
merged["backup_e2b_gc_script_path"] = str(dummy / "qops-e2b-gc")
pathlib.Path(sys.argv[2]).write_text(yaml.safe_dump(merged))
PY
  cat >"${BATS_TMPDIR}/docker.service" <<'EOF'
[Unit]
Description=stub docker.service for systemd-analyze verify
[Service]
Type=oneshot
ExecStart=/bin/true
RemainAfterExit=yes
EOF
  for tmpl in \
    ansible/roles/backup/templates/qops-backup.service.j2 \
    ansible/roles/backup/templates/qops-e2b-gc.service.j2 \
    ansible/roles/backup/templates/qops-backup.timer.j2 \
    ansible/roles/backup/templates/qops-e2b-gc.timer.j2
  do
    name="$(basename "${tmpl}" .j2)"
    dest="${BATS_TMPDIR}/${name}"
    "${RENDER}" "${tmpl}" "${vars}" >"${dest}"
    run systemd-analyze verify "${dest}"
    echo "verify ${name}: status=$status"
    echo "${output}"
    [ "$status" -eq 0 ]
  done
}
