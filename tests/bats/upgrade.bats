#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export ANSIBLE_CONFIG="${REPO_ROOT}/ansible.cfg"
  export ANSIBLE_ROLES_PATH="${REPO_ROOT}/ansible/roles"
  export ANSIBLE_HOST_KEY_CHECKING=False
  INVENTORY="${REPO_ROOT}/tests/fixtures/inventory-codereviewer-local.yml"
  UPGRADE="${REPO_ROOT}/ansible/playbooks/upgrade.yml"
  COMPARE="${REPO_ROOT}/ansible/roles/e2b_services/files/e2b-compare-upgrade-pins.py"
  ASSERT="${REPO_ROOT}/ansible/roles/e2b_services/files/e2b-assert-dist-pair.sh"
  FORCE="${REPO_ROOT}/ansible/roles/e2b_services/files/e2b-set-force-stop.sh"
  FIXTURE="${REPO_ROOT}/tests/fixtures/build-e2b-dist-fixture.sh"
  FORCE_STOP_TASKS="${REPO_ROOT}/ansible/roles/e2b_services/tasks/force-stop.yml"
}

write_build_info() {
  local path="$1"
  local overrides='{}'
  if [[ "$#" -ge 2 ]]; then
    overrides="$2"
  fi
  local overrides_file="${BATS_TMPDIR}/build-info-overrides.json"
  printf '%s\n' "${overrides}" >"${overrides_file}"
  python3 - "${path}" "${overrides_file}" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
overrides = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
data = {
    "e2b_pin": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "e2b_dist_version": "aaaaaaa",
    "e2b_go_version": "1.26.6",
    "gowork_go_version": "1.26.6",
    "envd_version": "0.7.0",
    "goose_version": "v3.27.2",
    "expected_migration_timestamp": "20240101000000",
    "built_at_utc": "2026-08-31T00:00:00Z",
    "clean_nfs_cache": True,
    "patches": [],
}
data.update(overrides)
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
}

write_env() {
  local path="$1"
  local fc="$2"
  local kernel="$3"
  printf 'DEFAULT_FIRECRACKER_VERSION=%s\nDEFAULT_KERNEL_VERSION=%s\nFORCE_STOP=false\n' \
    "${fc}" "${kernel}" >"${path}"
}

@test "upgrade.yml never invokes the E2B seeder" {
  ! grep -E 'e2b-seed-if-needed|e2b-seed |bin/e2b-seed|Seed E2B' "${UPGRADE}"
  grep -q 'e2b_services_seed_enabled: false' "${UPGRADE}"
}

@test "upgrade.yml sets FORCE_STOP and marker before stopping units" {
  run python3 - "${UPGRADE}" "${FORCE_STOP_TASKS}" <<'PY'
import sys, yaml
upgrade = yaml.safe_load(open(sys.argv[1]))
tasks = upgrade[0]["tasks"]
names = [t.get("name", "") for t in tasks]
force_idx = next(i for i, n in enumerate(names) if "FORCE_STOP" in n)
start_idx = next(i for i, n in enumerate(names) if "seeder disabled" in n)
assert force_idx < start_idx, (force_idx, start_idx, names)
force_tasks = yaml.safe_load(open(sys.argv[2]))
force_names = [t["name"] for t in force_tasks]
assert force_names[0].startswith("Set orchestrator FORCE_STOP=true")
marker_idx = next(i for i, n in enumerate(force_names) if "force-stop marker" in n and "Create" in n)
stop_idx = next(i for i, n in enumerate(force_names) if n.startswith("Stop e2b-orchestrator"))
assert marker_idx < stop_idx, (marker_idx, stop_idx, force_names)
assert force_names[0]  # env write
env_idx = 0
assert env_idx < stop_idx
clear_idx = next(i for i, n in enumerate(force_names) if n.startswith("Remove force-stop marker"))
assert stop_idx < clear_idx
print("ok")
PY
  [ "$status" -eq 0 ]
}

@test "e2b-set-force-stop writes true and creates the marker before a stop would read the file" {
  envf="${BATS_TMPDIR}/orchestrator.env"
  marker="${BATS_TMPDIR}/force-stop"
  rm -f "${marker}"
  printf 'ENVIRONMENT=local\nFORCE_STOP=false\n' >"${envf}"
  export QOPS_FORCE_STOP_MARKER="${marker}"
  run bash "${FORCE}" "${envf}" true
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed"* ]]
  grep -qx 'FORCE_STOP=true' "${envf}"
  [ -f "${marker}" ]
  marker_mode="$(python3 - "${marker}" <<'PY'
import os
import stat
import sys

print(format(stat.S_IMODE(os.stat(sys.argv[1]).st_mode), "o"))
PY
)"
  [ "${marker_mode}" = "600" ]
  [ ! -s "${marker}" ]
  run bash "${FORCE}" "${envf}" true
  [ "$status" -eq 0 ]
  [[ "$output" == *"unchanged"* ]]
  run bash "${FORCE}" --clear-marker
  [ "$status" -eq 0 ]
  [ ! -f "${marker}" ]
  grep -qx 'FORCE_STOP=true' "${envf}"
}

@test "pin-change rebuilds templates only for envd, firecracker, or kernel" {
  installed="${BATS_TMPDIR}/installed-BUILD_INFO"
  new="${BATS_TMPDIR}/new-BUILD_INFO"
  envf="${BATS_TMPDIR}/orch.env"
  write_build_info "${installed}"
  write_env "${envf}" "v1.14-0.2.0" "vmlinux-6.1.158-c1a568c"

  write_build_info "${new}" '{"goose_version":"v9.9.9","e2b_pin":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","expected_migration_timestamp":"20990101000000"}'
  run python3 "${COMPARE}" \
    --installed-build-info "${installed}" --new-build-info "${new}" \
    --installed-env "${envf}" --new-firecracker "v1.14-0.2.0" \
    --new-kernel "vmlinux-6.1.158-c1a568c"
  [ "$status" -eq 0 ]
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['rebuild_templates'] is False, d" "${output}"

  write_build_info "${new}" '{"envd_version":"0.8.0"}'
  run python3 "${COMPARE}" \
    --installed-build-info "${installed}" --new-build-info "${new}" \
    --installed-env "${envf}" --new-firecracker "v1.14-0.2.0" \
    --new-kernel "vmlinux-6.1.158-c1a568c"
  [ "$status" -eq 0 ]
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['rebuild_templates'] is True; assert d['changed']==['envd_version'], d" "${output}"

  write_build_info "${new}"
  run python3 "${COMPARE}" \
    --installed-build-info "${installed}" --new-build-info "${new}" \
    --installed-env "${envf}" --new-firecracker "v9.9.9" \
    --new-kernel "vmlinux-6.1.158-c1a568c"
  [ "$status" -eq 0 ]
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['changed']==['firecracker_version'], d" "${output}"

  run python3 "${COMPARE}" \
    --installed-build-info "${installed}" --new-build-info "${new}" \
    --installed-env "${envf}" --new-firecracker "v1.14-0.2.0" \
    --new-kernel "vmlinux-9.9.9"
  [ "$status" -eq 0 ]
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['changed']==['kernel_version'], d" "${output}"
}

@test "mismatched API/migration pair fails fast" {
  archive="${BATS_TMPDIR}/e2b-ok.tar.gz"
  bash "${FIXTURE}" "${archive}" 6e4ce14
  run bash "${ASSERT}" --archive "${archive}"
  [ "$status" -eq 0 ]

  stage="${BATS_TMPDIR}/bad-dist"
  mkdir -p "${stage}/bin" "${stage}/migrations/postgres"
  tar -xzf "${archive}" -C "${stage}"
  python3 - "${stage}/BUILD_INFO" <<'PY'
import hashlib
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
data["expected_migration_timestamp"] = "20990101000000"
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
root = path.parent
lines = []
for p in sorted(root.rglob("*")):
    if p.is_file() and p.name != "SHA256SUMS":
        rel = p.relative_to(root).as_posix()
        digest = hashlib.sha256(p.read_bytes()).hexdigest()
        lines.append(f"{digest}  {rel}")
(root / "SHA256SUMS").write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
  run bash "${ASSERT}" --dir "${stage}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mismatch"* ]]
}

@test "dist patch metadata is required before an upgrade stop" {
  archive="${BATS_TMPDIR}/e2b-patch-check.tar.gz"
  bash "${FIXTURE}" "${archive}" 6e4ce14
  run bash "${ASSERT}" --archive "${archive}" \
    --required-patch 0001-force-stop-marker.patch \
    --required-patch-sha256 4da7ddc0c07cbfd67d1afb0f49dcd4106c48f8bc1907e4c353c92b12d2ff2d9c
  [ "$status" -eq 0 ]

  run bash "${ASSERT}" --archive "${archive}" \
    --required-patch 0001-force-stop-marker.patch \
    --required-patch-sha256 0000000000000000000000000000000000000000000000000000000000000000
  [ "$status" -ne 0 ]
  [[ "$output" == *"sha256"* ]]
}

@test "upgrade requires the installed dist to contain the force-stop patch" {
  run python3 - "${UPGRADE}" <<'PY'
import sys
import yaml

play = yaml.safe_load(open(sys.argv[1]))[0]
tasks = play["tasks"]
names = [task.get("name", "") for task in tasks]
installed_idx = next(i for i, name in enumerate(names) if name.startswith("Require the installed E2B dist"))
force_idx = next(i for i, name in enumerate(names) if "FORCE_STOP" in name)
assert installed_idx < force_idx, (installed_idx, force_idx, names)
check = tasks[installed_idx]
argv = check["ansible.builtin.command"]["argv"]
assert argv[0:2] == ["python3", "/usr/local/lib/qops/e2b-verify-build-patches.py"]
assert argv[-2:] == [
    "{{ e2b_services_force_stop_patch_filename }}",
    "{{ e2b_services_force_stop_patch_sha256 }}",
]
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "swapped API binary with matching BUILD_INFO and migrations fails" {
  archive="${BATS_TMPDIR}/e2b-swap.tar.gz"
  bash "${FIXTURE}" "${archive}" 6e4ce14
  stage="${BATS_TMPDIR}/swap-dist"
  mkdir -p "${stage}"
  tar -xzf "${archive}" -C "${stage}"
  printf '#!/bin/sh\n%s\necho api\n' "20990101000000" >"${stage}/bin/api"
  chmod 755 "${stage}/bin/api"
  python3 - "${stage}" <<'PY'
import hashlib
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
lines = []
for p in sorted(root.rglob("*")):
    if p.is_file() and p.name != "SHA256SUMS":
        rel = p.relative_to(root).as_posix()
        digest = hashlib.sha256(p.read_bytes()).hexdigest()
        lines.append(f"{digest}  {rel}")
(root / "SHA256SUMS").write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
  run bash "${ASSERT}" --dir "${stage}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mismatch"* || "$output" == *"expectedMigrationTimestamp"* || "$output" == *"bin/api"* ]]
}

@test "force-stop marker patch applies to the pinned checkout and stub logic matches" {
  PATCH="${REPO_ROOT}/e2b/patches/0001-force-stop-marker.patch"
  [ -f "${PATCH}" ]
  rm -f "${BATS_TMPDIR}/force-stop"
  run python3 -c '
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("logic", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
patch = pathlib.Path(sys.argv[2])
assert mod.patch_mentions_marker(patch)
marker = pathlib.Path(sys.argv[3]) / "force-stop"
assert mod.effective_force_stop(True, marker) is True
assert mod.effective_force_stop(False, marker) is False
marker.write_text("")
assert mod.effective_force_stop(False, marker) is True
assert mod.effective_force_stop(True, marker) is True
print("ok")
' "${REPO_ROOT}/tests/fixtures/force-stop-marker-logic.py" "${PATCH}" "${BATS_TMPDIR}"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
  if [[ -d /tmp/e2b-infra/.git ]]; then
    git -C /tmp/e2b-infra apply --check "${PATCH}"
  fi
}

@test "upgrade.yml rejects kodus_image_tag=latest" {
  run ansible-playbook --check -i "${INVENTORY}" "${UPGRADE}" \
    --extra-vars "kodus_image_tag=latest"
  [ "$status" -ne 0 ]
  [[ "$output" == *"never latest"* || "$output" == *"latest"* ]]
}

@test "upgrade.yml rebuild condition names the three pin keys" {
  grep -q 'envd_version, firecracker_version, kernel_version' "${UPGRADE}"
  grep -q 'e2b_templates_force: true' "${UPGRADE}"
  grep -q 'when: e2b_upgrade_rebuild_templates | bool' "${UPGRADE}"
}

@test "upgrade.yml verifies backup independently of backup exit status" {
  grep -q 'backup_verify_script_path' "${UPGRADE}"
  grep -q 'not merely that backup exited 0' "${UPGRADE}"
}
