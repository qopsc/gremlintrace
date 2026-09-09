#!/usr/bin/env bash
# Copy e2b/templates onto the host without node_modules.
set -euo pipefail

SRC="${1:?source directory required}"
DEST="${2:?destination directory required}"

if [[ ! -d "${SRC}" ]]; then
  echo "template source missing: ${SRC}" >&2
  exit 1
fi
if [[ ! -f "${SRC}/package.json" || ! -f "${SRC}/build-templates.ts" ]]; then
  echo "template source is missing package.json or build-templates.ts" >&2
  exit 1
fi

mkdir -p "${DEST}"
src_stamp="$(python3 - "${SRC}" <<'PY'
import hashlib
import pathlib
import sys

src = pathlib.Path(sys.argv[1])
skip = {"node_modules", ".ci-stamp", ".vite", ".npm-ci-stamp"}
digest = hashlib.sha256()
for path in sorted(p for p in src.rglob("*") if p.is_file()):
    rel = path.relative_to(src)
    if any(part in skip for part in rel.parts):
        continue
    digest.update(str(rel).encode())
    digest.update(path.read_bytes())
print(digest.hexdigest())
PY
)"
stamp_file="${DEST}/.source-stamp"
if [[ -f "${stamp_file}" && "$(cat "${stamp_file}")" == "${src_stamp}" ]]; then
  echo unchanged
  exit 0
fi

if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete \
    --exclude node_modules \
    --exclude .ci-stamp \
    --exclude .vite \
    --exclude .npm-ci-stamp \
    --exclude .source-stamp \
    "${SRC}/" "${DEST}/"
else
  python3 - "${SRC}" "${DEST}" <<'PY'
import pathlib
import shutil
import sys

src = pathlib.Path(sys.argv[1])
dest = pathlib.Path(sys.argv[2])
skip = {"node_modules", ".ci-stamp", ".vite"}
if dest.exists():
    for child in dest.iterdir():
        if child.name in skip:
            continue
        if child.is_dir():
            shutil.rmtree(child)
        else:
            child.unlink()
for path in src.rglob("*"):
    rel = path.relative_to(src)
    if any(part in skip for part in rel.parts):
        continue
    target = dest / rel
    if path.is_dir():
        target.mkdir(parents=True, exist_ok=True)
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
PY
fi
printf '%s\n' "${src_stamp}" >"${stamp_file}"
echo installed
