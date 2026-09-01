#!/usr/bin/env bash
# Remove Local-registry templateId:buildId images that are not in the latest
# summary. Aliases are not Docker repositories; Local-registry tags are
# templateId:buildId. A requested docker rmi failure fails the play.
set -euo pipefail

SUMMARY_PATH="${1:?summary json required}"
DOCKER_BIN="${2:-docker}"

if [[ ! -f "${SUMMARY_PATH}" ]]; then
  echo "summary missing: ${SUMMARY_PATH}" >&2
  exit 1
fi

if ! command -v "${DOCKER_BIN}" >/dev/null 2>&1; then
  echo "docker not available; skipping template image prune" >&2
  echo unchanged
  exit 0
fi

python3 - "${SUMMARY_PATH}" "${DOCKER_BIN}" <<'PY'
import json
import subprocess
import sys

summary_path, docker_bin = sys.argv[1], sys.argv[2]
data = json.load(open(summary_path, encoding="utf-8"))
keep = set()
template_ids = set()
for row in data.get("templates", []):
    template_id = row.get("templateId")
    build_id = row.get("buildId")
    if template_id:
        template_ids.add(template_id)
    if template_id and build_id:
        keep.add(f"{template_id}:{build_id}")

if not keep:
    print("unchanged")
    raise SystemExit(0)

listed = subprocess.run(
    [docker_bin, "images", "--format", "{{.Repository}}:{{.Tag}}"],
    check=False,
    capture_output=True,
    text=True,
)
if listed.returncode != 0:
    sys.stderr.write(listed.stderr)
    raise SystemExit(listed.returncode)

removed = 0
for image in listed.stdout.splitlines():
    image = image.strip()
    if not image or image.endswith(":latest"):
        continue
    repo, _, tag = image.rpartition(":")
    if not tag or tag == "<none>":
        continue
    if repo not in template_ids:
        continue
    if image in keep:
        continue
    rm = subprocess.run([docker_bin, "rmi", "-f", image], check=False, capture_output=True, text=True)
    if rm.returncode != 0:
        sys.stderr.write(rm.stderr or f"docker rmi failed for {image}\n")
        raise SystemExit(rm.returncode or 1)
    removed += 1

print("changed" if removed else "unchanged")
PY
