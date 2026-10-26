#!/bin/sh
# Unmodified, pinned BSD-3-Clause source; extracted only into the build cache.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
out="$repo_root/build/littlefs"
revision=6cb4e86540eca0d9ba62500a298385c9d863c8be
mkdir -p "$out"
archive="$out/source.tar.gz"
if [ ! -f "$archive" ]; then
    curl -fL --retry 2 "https://codeload.github.com/littlefs-project/littlefs/tar.gz/$revision" -o "$archive.next"
    mv "$archive.next" "$archive"
fi
python3 - "$archive" "$revision" <<'PY'
from pathlib import Path
import hashlib,sys,tarfile
archive,revision=Path(sys.argv[1]),sys.argv[2]
if hashlib.sha256(archive.read_bytes()).hexdigest() != '4803faf6db6c60093558a315a10c50926d2cfa5668a3f03fa2523fd09b10b747':
    raise SystemExit('littlefs archive checksum mismatch')
with tarfile.open(archive) as source:
    for name in ('lfs.c','lfs.h','lfs_util.c','lfs_util.h','LICENSE.md','SPEC.md'):
        data=source.extractfile('littlefs-'+revision+'/'+name).read()
        target=archive.parent/('littlefs-'+revision)/name
        target.parent.mkdir(parents=True,exist_ok=True)
        if not target.exists() or target.read_bytes()!=data: target.write_bytes(data)
print(archive.parent/('littlefs-'+revision))
PY
