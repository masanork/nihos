#!/bin/sh
# Pinned, unmodified BSD-2-Clause OpenJPEG source; used only by the photo decoder.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
out="$repo_root/build/openjpeg"
mkdir -p "$out"
archive="$out/openjpeg-2.5.4.tar.gz"
if [ ! -f "$archive" ]; then
    curl -fLsS --retry 2 https://codeload.github.com/uclouvain/openjpeg/tar.gz/refs/tags/v2.5.4 -o "$archive.next"
    mv "$archive.next" "$archive"
fi
python3 - "$archive" <<'PY'
from pathlib import Path
import hashlib,sys,tarfile
path=Path(sys.argv[1])
if hashlib.sha256(path.read_bytes()).hexdigest()!='a695fbe19c0165f295a8531b1e4e855cd94d0875d2f88ec4b61080677e27188a':
    raise SystemExit('OpenJPEG archive checksum mismatch')
with tarfile.open(path) as source:
    for member in source.getmembers():
        if member.name.startswith('openjpeg-2.5.4/src/lib/openjp2/') or member.name=='openjpeg-2.5.4/LICENSE':
            if member.isfile():
                target=path.parent/member.name
                target.parent.mkdir(parents=True,exist_ok=True)
                data=source.extractfile(member).read()
                if not target.exists() or target.read_bytes()!=data:target.write_bytes(data)
print(path.parent/'openjpeg-2.5.4')
PY
