#!/usr/bin/env bash
# Pack e2b/templates on the CONTROL machine into a deterministic tar.gz that
# excludes node_modules and build caches, so the transfer to the host is a
# single small file whose bytes only change when the sources do (keeps
# ansible.builtin.copy at changed=0 on re-runs).
#
#   pack-template-sources.sh SRC_DIR OUT_TAR_GZ   -> prints the source stamp
set -euo pipefail

SRC="${1:?source directory required}"
OUT="${2:?output tarball path required}"

if [[ ! -f "${SRC}/package.json" || ! -f "${SRC}/build-templates.ts" ]]; then
  echo "template source is missing package.json or build-templates.ts: ${SRC}" >&2
  exit 1
fi

python3 - "${SRC}" "${OUT}" <<'PY'
import gzip
import hashlib
import io
import pathlib
import sys
import tarfile

src = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
# Same skip set as install-template-sources.sh so both compute one stamp.
skip = {"node_modules", ".ci-stamp", ".vite", ".npm-ci-stamp", ".source-stamp"}

files = []
for path in sorted(p for p in src.rglob("*") if p.is_file()):
    rel = path.relative_to(src)
    if any(part in skip for part in rel.parts):
        continue
    files.append((rel, path))

digest = hashlib.sha256()
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as tar:
    for rel, path in files:
        data = path.read_bytes()
        digest.update(str(rel).encode())
        digest.update(data)
        info = tarfile.TarInfo(name=str(rel))
        info.size = len(data)
        info.mtime = 0
        info.uid = info.gid = 0
        info.uname = info.gname = "root"
        info.mode = 0o755 if path.stat().st_mode & 0o100 else 0o644
        tar.addfile(info, io.BytesIO(data))

out.parent.mkdir(parents=True, exist_ok=True)
with open(out, "wb") as handle:
    with gzip.GzipFile(fileobj=handle, mode="wb", mtime=0, filename="") as gz:
        gz.write(buf.getvalue())
print(digest.hexdigest())
PY
