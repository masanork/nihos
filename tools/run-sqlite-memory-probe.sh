#!/bin/sh
# Host-only memory database; no native SQLite link or persistent VFS claim.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
zig=$(sh tools/bootstrap-zig.sh)
out_dir="$repo_root/build/sqlite"
mkdir -p "$out_dir"
archive="$out_dir/sqlite-amalgamation-3540100.zip"
if [ ! -f "$archive" ]; then
    curl -fL --retry 2 https://www.sqlite.org/2026/sqlite-amalgamation-3540100.zip -o "$archive"
fi
python3 - "$archive" <<'PY'
from pathlib import Path
import hashlib, sys, zipfile
archive = Path(sys.argv[1])
expected = '92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30'
if hashlib.sha3_256(archive.read_bytes()).hexdigest() != expected:
    raise SystemExit('SQLite archive checksum mismatch')
with zipfile.ZipFile(archive) as source:
    for name in ('sqlite3.c', 'sqlite3.h'):
        target = archive.parent / 'sqlite-amalgamation-3540100' / name
        data = source.read('sqlite-amalgamation-3540100/' + name)
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists() or target.read_bytes() != data:
            target.write_bytes(data)
PY
sh tools/run-c-allocator-probe.sh
"$zig" cc -c -O2 -g -std=c11 -Wall -Wextra -Werror -Wno-unused-parameter \
    -DSQLITE_THREADSAFE=0 -DSQLITE_OS_OTHER=1 -DSQLITE_TEMP_STORE=3 \
    -DSQLITE_DEFAULT_PAGE_SIZE=1024 -DSQLITE_DEFAULT_MEMSTATUS=1 \
    -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_WAL -DSQLITE_OMIT_AUTOINIT \
    -DSQLITE_OMIT_LOOKASIDE -DSQLITE_ENABLE_API_ARMOR \
    "$out_dir/sqlite-amalgamation-3540100/sqlite3.c" -o "$out_dir/sqlite3.o"
"$zig" cc -O2 -g -std=c11 -Wall -Wextra -Wconversion -Werror \
    -I include -I "$out_dir/sqlite-amalgamation-3540100" \
    probes/sqlite/memory_probe.c "$out_dir/sqlite3.o" \
    build/c-allocator/allocator.o -o "$out_dir/memory-probe"
"$out_dir/memory-probe" "${1:-64}"
