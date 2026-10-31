#!/bin/sh
# Compile-only portability check, including the permanent owner and fixed heap.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
zig=${ZIG:-$(tools/bootstrap-zig.sh)}
tools/bootstrap-sqlite.sh >/dev/null
out=build/sqld-rv32
headers="$repo_root/.tools/zig-0.17.0/lib/libc/include"
mkdir -p "$out"
"$zig" build-obj -target riscv32-freestanding-none -mcpu=generic_rv32+m+a+c+zicsr+zifencei \
 -O ReleaseSmall src/storage/store_abi.zig -femit-bin="$out/store.o"
for source in sqld sqlite_store_vfs; do
 "$zig" cc -c -target riscv32-freestanding-none -mcpu=generic_rv32+m+a+c+zicsr+zifencei \
  -Oz -std=c11 -ffreestanding -fno-builtin -fno-pic -ffunction-sections -fdata-sections -fstack-size-section \
  -Wall -Wextra -Werror -isystem "$headers/riscv32-linux-musl" -isystem "$headers/generic-musl" \
  -isystem "$headers/riscv-linux-any" -I include -I build/sqlite/sqlite-amalgamation-3540100 \
  "src/services/$source.c" -o "$out/$source.o"
done
python3 tools/sqld_native_build.py "$out/native" > "$out/native-build.json"
printf '%s\n' 'sqld/checkpoint VFS and permanent owner RV32 objects compiled; no media execution in this check'
