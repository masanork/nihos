#!/bin/sh
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
zig=$(sh "$repo_root/tools/bootstrap-zig.sh")
sqlite=$(sh "$repo_root/tools/bootstrap-sqlite.sh")
out="$repo_root/build/sqlite-cache"
mkdir -p "$out"
printf 'pub const cache_experiment = true;\n' > "$out/build-options.zig"
"$zig" fmt --check "$repo_root/probes/sqlite/store_bridge.zig"
"$zig" cc -c -O2 -g -std=c11 -Wall -Wextra -Werror -Wno-unused-parameter \
    -DSQLITE_THREADSAFE=0 -DSQLITE_OS_OTHER=1 -DSQLITE_TEMP_STORE=3 -DSQLITE_ZERO_MALLOC=1 \
    -DSQLITE_DEFAULT_PAGE_SIZE=4096 -DSQLITE_MAX_DEFAULT_PAGE_SIZE=4096 -DSQLITE_MAX_MMAP_SIZE=0 \
    -DSQLITE_DEFAULT_MEMSTATUS=1 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_WAL -DSQLITE_OMIT_AUTOINIT \
    -DSQLITE_ENABLE_API_ARMOR "$sqlite/sqlite3.c" -o "$out/sqlite3.o"
# The host comparison needs SQLite's real libc methods; ZERO_MALLOC is used
# only in the dedicated bounded build added after the comparison.
"$zig" cc -c -O2 -g -std=c11 -Wall -Wextra -Werror -Wno-unused-parameter \
    -DSQLITE_THREADSAFE=0 -DSQLITE_OS_OTHER=1 -DSQLITE_TEMP_STORE=3 \
    -DSQLITE_DEFAULT_PAGE_SIZE=4096 -DSQLITE_MAX_DEFAULT_PAGE_SIZE=4096 -DSQLITE_MAX_MMAP_SIZE=0 \
    -DSQLITE_DEFAULT_MEMSTATUS=1 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_WAL -DSQLITE_OMIT_AUTOINIT \
    -DSQLITE_ENABLE_API_ARMOR "$sqlite/sqlite3.c" -o "$out/sqlite3-host.o"
"$zig" cc -c -O2 -g -std=c11 -Wall -Wextra -Wconversion -Werror \
    -I "$sqlite" -I "$repo_root/probes/sqlite" "$repo_root/probes/sqlite/store_vfs.c" -o "$out/store-vfs.o"
"$zig" cc -c -O2 -g -std=c11 -Wall -Wextra -Wconversion -Werror -DNIH_SQLITE_CACHE_EXPERIMENT \
    -I "$sqlite" -I "$repo_root/probes/sqlite" "$repo_root/probes/sqlite/store_probe.c" -o "$out/store-probe.o"
"$zig" cc -c -O2 -g -std=c11 -Wall -Wextra -Wconversion -Werror \
    -I "$sqlite" -I "$repo_root/probes/sqlite" -I "$repo_root/include" \
    "$repo_root/probes/sqlite/store_allocator.c" -o "$out/store-allocator.o"
for flavor in host bounded; do
    sqlite_object="$out/sqlite3-host.o"
    binary="$out/sqlite-cache-probe"
    if [ "$flavor" = bounded ]; then sqlite_object="$out/sqlite3.o"; binary="$out/sqlite-bounded-probe"; fi
"$zig" build-exe -O safe -lc "$sqlite_object" "$out/store-vfs.o" "$out/store-probe.o" "$out/store-allocator.o" \
    --dep checkpoint_service --dep file_media --dep spsc_ring --dep build_options --dep host_allocator \
    -Mroot="$repo_root/probes/sqlite/store_bridge.zig" \
    -Mbuild_options="$out/build-options.zig" \
    -Mcheckpoint_service="$repo_root/src/storage/checkpoint_service.zig" \
    -Mfile_media="$repo_root/src/storage/file_media.zig" -Mspsc_ring="$repo_root/src/kernel/spsc_ring.zig" \
    --dep buddy_heap --dep task_resources -Mhost_allocator="$repo_root/probes/allocator/host.zig" \
    -Mbuddy_heap="$repo_root/src/kernel/buddy_heap.zig" -Mtask_resources="$repo_root/src/kernel/task_resources.zig" \
    -femit-bin="$binary"
done
if [ "${1:-}" = '--build-only' ]; then exit 0; fi
result_dir=$(mktemp -d "$out/process.XXXXXX")
python3 "$repo_root/tools/sqlite_cache_probe.py" "$out/sqlite-cache-probe" "$out/sqlite-bounded-probe" "$result_dir"
