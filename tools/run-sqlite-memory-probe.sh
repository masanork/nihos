#!/bin/sh
# Host-only memory database; no native SQLite link or persistent VFS claim.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
zig=$(sh tools/bootstrap-zig.sh)
out_dir="$repo_root/build/sqlite"
mkdir -p "$out_dir"
sh tools/bootstrap-sqlite.sh >/dev/null
sh tools/run-c-allocator-probe.sh
"$zig" cc -c -O2 -g -std=c11 -Wall -Wextra -Werror -Wno-unused-parameter \
    -DSQLITE_THREADSAFE=0 -DSQLITE_ZERO_MALLOC=1 -DSQLITE_OS_OTHER=1 -DSQLITE_TEMP_STORE=3 \
    -DSQLITE_DEFAULT_PAGE_SIZE=1024 -DSQLITE_DEFAULT_MEMSTATUS=1 \
    -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_WAL -DSQLITE_OMIT_AUTOINIT \
    -DSQLITE_OMIT_LOOKASIDE -DSQLITE_ENABLE_API_ARMOR \
    "$out_dir/sqlite-amalgamation-3540100/sqlite3.c" -o "$out_dir/sqlite3.o"
"$zig" cc -O2 -g -std=c11 -Wall -Wextra -Wconversion -Werror \
    -I include -I "$out_dir/sqlite-amalgamation-3540100" \
    probes/sqlite/memory_probe.c probes/sqlite/noio_vfs.c "$out_dir/sqlite3.o" \
    build/c-allocator/allocator.o -o "$out_dir/memory-probe"
"$out_dir/memory-probe" "${1:-64}"
"$zig" cc -O2 -g -pthread -std=c11 -Wall -Wextra -Wconversion -Werror \
    -DNIH_SQLITE_TESTING -I include -I "$out_dir/sqlite-amalgamation-3540100" \
    src/services/sqlite_session.c probes/sqlite/session_probe.c probes/sqlite/noio_vfs.c \
    "$out_dir/sqlite3.o" build/c-allocator/allocator.o -o "$out_dir/session-probe"
"$out_dir/session-probe"
"$zig" cc -O2 -g -pthread -std=c11 -Wall -Wextra -Wconversion -Werror \
    -I include -I "$out_dir/sqlite-amalgamation-3540100" \
    src/services/sqlite_session.c probes/sqlite/production_probe.c probes/sqlite/noio_vfs.c \
    "$out_dir/sqlite3.o" build/c-allocator/allocator.o -o "$out_dir/session-normal-probe"
"$out_dir/session-normal-probe"
