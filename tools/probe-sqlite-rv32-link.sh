#!/bin/sh
# Symbol-closed standalone link, not the production ESP32-P4 image/map/boot.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
zig=$(sh tools/bootstrap-zig.sh)
sh tools/probe-sqlite-rv32.sh
out="$repo_root/build/sqlite-link"
mkdir -p "$out/host"
# Host-execute the same fixed-context oracle, with REAL retained and UTC-only.
"$zig" cc -c -Oz -std=c11 -ffreestanding -fno-builtin -DSQLITE_THREADSAFE=0 \
    -DSQLITE_ZERO_MALLOC=1 -DSQLITE_OS_OTHER=1 -DSQLITE_TEMP_STORE=3 \
    -DSQLITE_DEFAULT_PAGE_SIZE=1024 -DSQLITE_DEFAULT_MEMSTATUS=1 -DSQLITE_OMIT_LOCALTIME \
    -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_WAL -DSQLITE_OMIT_AUTOINIT \
    -DSQLITE_OMIT_LOOKASIDE -DSQLITE_ENABLE_API_ARMOR \
    build/sqlite/sqlite-amalgamation-3540100/sqlite3.c -o "$out/host/sqlite3.o"
"$zig" build-obj -O safe -fllvm -fno-stack-check -fno-stack-protector \
    --dep buddy_heap --dep task_resources -Mroot=probes/sqlite/rv32_link.zig \
    -Mbuddy_heap=src/kernel/buddy_heap.zig -Mtask_resources=src/kernel/task_resources.zig \
    -femit-bin="$out/host/oracle.o"
"$zig" cc -Oz -g -std=c11 -ffreestanding -fno-builtin -Wall -Wextra -Wconversion -Werror \
    -I include -I build/sqlite/sqlite-amalgamation-3540100 \
    src/compat/c_strings.c src/services/sqlite_session.c probes/sqlite/noio_vfs.c \
    probes/sqlite/link_host_main.c "$out/host/oracle.o" "$out/host/sqlite3.o" -o "$out/host/probe"
"$out/host/probe"
# Exercise the actual compatibility functions with the TLS owner/OOM oracle too.
sh tools/run-c-allocator-probe.sh
"$zig" cc -Oz -g -pthread -std=c11 -ffreestanding -fno-builtin \
    -Wall -Wextra -Wconversion -Werror -I include -I build/sqlite/sqlite-amalgamation-3540100 \
    src/compat/c_strings.c probes/sqlite/memory_probe.c probes/sqlite/noio_vfs.c \
    build/c-allocator/allocator.o "$out/host/sqlite3.o" -o "$out/host/memory-probe"
"$out/host/memory-probe" profile
"$zig" cc -Oz -g -pthread -std=c11 -ffreestanding -fno-builtin \
    -Wall -Wextra -Wconversion -Werror -DNIH_SQLITE_TESTING \
    -I include -I build/sqlite/sqlite-amalgamation-3540100 \
    src/compat/c_strings.c src/services/sqlite_session.c probes/sqlite/session_probe.c \
    probes/sqlite/noio_vfs.c build/c-allocator/allocator.o "$out/host/sqlite3.o" \
    -o "$out/host/session-probe"
"$out/host/session-probe"
headers="$repo_root/.tools/zig-0.17.0/lib/libc/include"
for abi in ilp32 ilp32f; do
    cpu=generic_rv32+m+a+c+zicsr+zifencei
    if [ "$abi" = ilp32f ]; then cpu=generic_rv32+m+a+c+f+zicsr+zifencei; fi
    directory="$out/$abi"
    mkdir -p "$directory"
    for name in sqlite3 session strings vfs; do
        case "$name" in
            sqlite3) source=build/sqlite/sqlite-amalgamation-3540100/sqlite3.c ;;
            session) source=src/services/sqlite_session.c ;;
            strings) source=src/compat/c_strings.c ;;
            vfs) source=probes/sqlite/noio_vfs.c ;;
        esac
        "$zig" cc -c -target riscv32-freestanding-none -mcpu="$cpu" -mabi="$abi" \
            -Oz -std=c11 -ffreestanding -fno-builtin -fno-pic -ffunction-sections -fdata-sections \
            -fno-stack-protector -fno-unwind-tables -fno-asynchronous-unwind-tables \
            -isystem "$headers/riscv32-linux-musl" -isystem "$headers/generic-musl" \
            -isystem "$headers/riscv-linux-any" -I include -I build/sqlite/sqlite-amalgamation-3540100 \
            -DSQLITE_THREADSAFE=0 -DSQLITE_ZERO_MALLOC=1 -DSQLITE_OS_OTHER=1 \
            -DSQLITE_TEMP_STORE=3 -DSQLITE_DEFAULT_PAGE_SIZE=1024 -DSQLITE_DEFAULT_MEMSTATUS=1 \
            -DSQLITE_OMIT_LOCALTIME -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_WAL \
            -DSQLITE_OMIT_AUTOINIT -DSQLITE_OMIT_LOOKASIDE -DSQLITE_ENABLE_API_ARMOR \
            "$source" -o "$directory/$name.o"
    done
    "$zig" build-exe -target riscv32-freestanding-none -mcpu="$cpu" -O safe -fllvm \
        -fno-stack-check -fno-stack-protector -fno-unwind-tables -fno-strip \
        -fentry=nih_sqlite_link_probe -T probes/sqlite/rv32_link.ld --gc-sections \
        "$directory/sqlite3.o" "$directory/session.o" "$directory/strings.o" "$directory/vfs.o" \
        "build/sqlite-rv32/$abi-real-sql/abi.o" \
        -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
        --dep buddy_heap --dep task_resources -Mroot=probes/sqlite/rv32_link.zig \
        -target riscv32-freestanding-none -mcpu="$cpu" -O safe -Mbuddy_heap=src/kernel/buddy_heap.zig \
        -target riscv32-freestanding-none -mcpu="$cpu" -O safe -Mtask_resources=src/kernel/task_resources.zig \
        -femit-bin="$directory/sqlite-link.elf"
    echo "RV32 standalone $abi link passed"
done
for abi in ilp32 ilp32f; do
    python3 tools/check-sqlite-rv32-link.py "$out/$abi"
done
