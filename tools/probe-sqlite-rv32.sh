#!/bin/sh
# Compile-only port inventory. Does not change/link/execute native firmware.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
zig=$(sh tools/bootstrap-zig.sh)
python3 - <<'PY'
from pathlib import Path
import hashlib, zipfile
root = Path('build/sqlite')
archive = root / 'sqlite-amalgamation-3540100.zip'
if not archive.exists():
    raise SystemExit('First run sh tools/run-sqlite-memory-probe.sh for the pinned source')
if hashlib.sha3_256(archive.read_bytes()).hexdigest() != '92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30':
    raise SystemExit('SQLite archive digest mismatch')
with zipfile.ZipFile(archive) as source:
    for name in ('sqlite3.c', 'sqlite3.h'):
        member = 'sqlite-amalgamation-3540100/' + name
        if (root / member).read_bytes() != source.read(member):
            raise SystemExit('SQLite extracted source mismatch: ' + name)
PY
headers="$repo_root/.tools/zig-0.17.0/lib/libc/include"
for abi in ilp32 ilp32f; do
    cpu=generic_rv32+m+a+c+zicsr+zifencei
    if [ "$abi" = ilp32f ]; then cpu=generic_rv32+m+a+c+f+zicsr+zifencei; fi
    for policy in real-sql integer-sql; do
        out="$repo_root/build/sqlite-rv32/$abi-$policy"
        mkdir -p "$out"
        set --
        if [ "$policy" = integer-sql ]; then set -- -DSQLITE_OMIT_FLOATING_POINT; fi
        for source in sqlite3 session abi; do
            case "$source" in
                sqlite3) file=build/sqlite/sqlite-amalgamation-3540100/sqlite3.c ;;
                session) file=src/services/sqlite_session.c ;;
                abi) file=probes/sqlite/rv32_abi.c ;;
            esac
            "$zig" cc -c -target riscv32-freestanding-none -mcpu="$cpu" -mabi="$abi" \
                -Oz -std=c11 -ffreestanding -fno-pic -ffunction-sections -fdata-sections \
                -fno-stack-protector -fno-unwind-tables -fno-asynchronous-unwind-tables \
                -isystem "$headers/riscv32-linux-musl" -isystem "$headers/generic-musl" \
                -isystem "$headers/riscv-linux-any" \
                -DSQLITE_THREADSAFE=0 -DSQLITE_ZERO_MALLOC=1 -DSQLITE_OS_OTHER=1 \
                -DSQLITE_TEMP_STORE=3 -DSQLITE_DEFAULT_PAGE_SIZE=1024 -DSQLITE_DEFAULT_MEMSTATUS=1 \
                -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_WAL -DSQLITE_OMIT_AUTOINIT \
                -DSQLITE_OMIT_LOOKASIDE -DSQLITE_ENABLE_API_ARMOR "$@" \
                -I include -I build/sqlite/sqlite-amalgamation-3540100 "$file" -o "$out/$source.o"
        done
        python3 tools/check-sqlite-rv32-object.py "$out"
    done
done
