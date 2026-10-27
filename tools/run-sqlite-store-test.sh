#!/bin/sh
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
zig=$(sh "$repo_root/tools/bootstrap-zig.sh")
sqlite=$(sh "$repo_root/tools/bootstrap-sqlite.sh")
out="$repo_root/build/sqlite-store"
mkdir -p "$out"
"$zig" fmt --check "$repo_root/probes/sqlite/store_bridge.zig"
"$zig" cc -c -O2 -g -std=c11 -Wall -Wextra -Werror -Wno-unused-parameter \
    -DSQLITE_THREADSAFE=0 -DSQLITE_OS_OTHER=1 -DSQLITE_TEMP_STORE=3 \
    -DSQLITE_DEFAULT_PAGE_SIZE=4096 -DSQLITE_MAX_DEFAULT_PAGE_SIZE=4096 \
    -DSQLITE_MAX_MMAP_SIZE=0 -DSQLITE_DEFAULT_MEMSTATUS=1 \
    -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_WAL -DSQLITE_OMIT_AUTOINIT \
    -DSQLITE_ENABLE_API_ARMOR "$sqlite/sqlite3.c" -o "$out/sqlite3.o"
"$zig" cc -c -O2 -g -std=c11 -Wall -Wextra -Wconversion -Werror \
    -I "$sqlite" -I "$repo_root/probes/sqlite" "$repo_root/probes/sqlite/store_vfs.c" -o "$out/store-vfs.o"
"$zig" cc -c -O2 -g -std=c11 -Wall -Wextra -Wconversion -Werror \
    -I "$sqlite" -I "$repo_root/probes/sqlite" "$repo_root/probes/sqlite/store_probe.c" -o "$out/store-probe.o"
"$zig" build-exe -O safe -lc "$out/sqlite3.o" "$out/store-vfs.o" "$out/store-probe.o" \
    --dep checkpoint_service --dep file_media --dep spsc_ring \
    -Mroot="$repo_root/probes/sqlite/store_bridge.zig" \
    -Mcheckpoint_service="$repo_root/src/storage/checkpoint_service.zig" \
    -Mfile_media="$repo_root/src/storage/file_media.zig" \
    -Mspsc_ring="$repo_root/src/kernel/spsc_ring.zig" -femit-bin="$out/sqlite-store-probe"
if [ "${1:-}" = '--build-only' ]; then exit 0; fi
python3 - "$repo_root/probes/sqlite/store_vfs.c" "$out" <<'PYMUTANT'
from pathlib import Path
import difflib,sys
source=Path(sys.argv[1]).read_text()
needle='int rc = mapped(nih_store_sync(&f->handle), SQLITE_IOERR_FSYNC);'
assert source.count(needle)==1
mutant=source.replace(needle,'int rc = SQLITE_OK; /* Negative control: omit real VFS sync. */')
out=Path(sys.argv[2]);(out/'no-sync-vfs.c').write_text(mutant)
(out/'no-sync.diff').write_text(''.join(difflib.unified_diff(source.splitlines(True),mutant.splitlines(True),fromfile='source',tofile='mutant')))
PYMUTANT
"$zig" cc -c -O2 -g -std=c11 -Wall -Wextra -Wconversion -Werror \
    -I "$sqlite" -I "$repo_root/probes/sqlite" "$out/no-sync-vfs.c" -o "$out/no-sync-vfs.o"
"$zig" build-exe -O safe -lc "$out/sqlite3.o" "$out/no-sync-vfs.o" "$out/store-probe.o" \
    --dep checkpoint_service --dep file_media --dep spsc_ring \
    -Mroot="$repo_root/probes/sqlite/store_bridge.zig" \
    -Mcheckpoint_service="$repo_root/src/storage/checkpoint_service.zig" \
    -Mfile_media="$repo_root/src/storage/file_media.zig" \
    -Mspsc_ring="$repo_root/src/kernel/spsc_ring.zig" -femit-bin="$out/sqlite-store-no-sync"
result_dir=$(mktemp -d "$out/process.XXXXXX")
python3 "$repo_root/tools/sqlite_store_probe.py" "$out/sqlite-store-probe" "$result_dir" "$out/sqlite-store-no-sync"
