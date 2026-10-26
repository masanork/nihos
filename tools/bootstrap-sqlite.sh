#!/bin/sh
# Unmodified SQLite source cache shared by host and native qualification.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
out="$repo_root/build/sqlite"
mkdir -p "$out"
archive="$out/sqlite-amalgamation-3540100.zip"
if [ ! -f "$archive" ]; then
    curl -fL --retry 2 https://www.sqlite.org/2026/sqlite-amalgamation-3540100.zip -o "$archive.next"
    python3 - "$archive.next" <<'PY'
from pathlib import Path
import hashlib,sys
if hashlib.sha3_256(Path(sys.argv[1]).read_bytes()).hexdigest() != '92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30':
    raise SystemExit('SQLite archive checksum mismatch')
PY
    mv "$archive.next" "$archive"
fi
python3 - "$archive" <<'PY'
from pathlib import Path
import hashlib,sys,zipfile
archive=Path(sys.argv[1])
if hashlib.sha3_256(archive.read_bytes()).hexdigest() != '92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30':
    raise SystemExit('SQLite archive checksum mismatch')
with zipfile.ZipFile(archive) as source:
    for name in ('sqlite3.c','sqlite3.h'):
        member='sqlite-amalgamation-3540100/'+name
        target=archive.parent/member
        data=source.read(member)
        target.parent.mkdir(parents=True,exist_ok=True)
        if not target.exists() or target.read_bytes()!=data:target.write_bytes(data)
print(archive.parent/'sqlite-amalgamation-3540100')
PY
