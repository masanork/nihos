#!/bin/sh
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
zig=${ZIG:-$(tools/bootstrap-zig.sh)}
tools/bootstrap-sqlite.sh >/dev/null
out=build/sqld
sqlite=build/sqlite/sqlite-amalgamation-3540100
mkdir -p "$out"
"$zig" build-obj -O ReleaseSafe -fPIC src/storage/store_abi.zig -femit-bin="$out/store.o"
cc=${CC:-clang}
"$cc" -O2 -fPIC -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_WAL \
 -DSQLITE_TEMP_STORE=3 -DSQLITE_DEFAULT_PAGE_SIZE=4096 -DSQLITE_ENABLE_API_ARMOR \
 -c "$sqlite/sqlite3.c" -o "$out/sqlite.o"
case $(uname -s) in Darwin) shared='-dynamiclib';ext=dylib;install_name='-Wl,-install_name,@rpath/libsqld.dylib' ;; *) shared='-shared';ext=so;install_name='' ;; esac
"$cc" -O2 -g -fPIC -Wall -Wextra -Werror -std=c11 -I include -I "$sqlite" \
 "$shared" $install_name src/services/sqld.c src/services/sqlite_store_vfs.c tools/sqld_host.c \
 "$out/store.o" "$out/sqlite.o" -pthread -lm -o "$out/libsqld.$ext"
"$cc" -O2 -g -Wall -Wextra -Werror -std=c11 -DNIH_SQLD_HOST_MAIN -I include -I "$sqlite" \
 src/services/sqld.c src/services/sqlite_store_vfs.c tools/sqld_host.c \
 "$out/store.o" "$out/sqlite.o" -pthread -lm -o "$out/sqld-host"
printf '%s\n' "$repo_root/$out/sqld-host"
