#!/bin/sh
# Compile the pinned decoder without OS, threads or I/O entry points.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
destination=${1:-"$repo_root/build/photo-host"}
target=${2:-host}
source_dir=$(sh "$repo_root/tools/bootstrap-openjpeg.sh")/src/lib/openjp2
mkdir -p "$destination"
rm -f "$destination/photo_ht_dec.o"
compiler="$repo_root/.tools/zig-0.17.0/zig"
set --
if [ "$target" = rv32 ]; then
    set -- -target riscv32-freestanding-none -mcpu=generic_rv32+m+a+c+zicsr+zifencei -mabi=ilp32
    headers="$repo_root/.tools/zig-0.17.0/lib/libc/include"
    set -- "$@" -isystem "$headers/riscv32-linux-musl" -isystem "$headers/generic-musl" -isystem "$headers/riscv-linux-any"
elif [ "$target" = host ] && [ "${NIHOS_PHOTO_SANITIZE:-0}" = 1 ]; then
    set -- -fsanitize=address,undefined -fno-omit-frame-pointer
elif [ "$target" != host ]; then echo 'target must be host or rv32' >&2; exit 1
fi
for name in bio cio dwt event function_list image invert j2k jp2 mct mqc openjpeg pi sparse_array t1 t2 tcd tgt thread; do
    "$compiler" cc "$@" -c -Oz -std=c11 -DNDEBUG -DOPJ_STATIC -include "$repo_root/probes/photo/noio.h" \
        -ffreestanding -fno-builtin -ffunction-sections -fdata-sections \
        -fno-stack-protector -fno-unwind-tables -fno-asynchronous-unwind-tables -fstack-size-section \
        -I "$repo_root/probes/photo" -I "$source_dir" \
        "$source_dir/$name.c" -o "$destination/photo_$name.o"
done
for adapter in decoder ht_stub; do
"$compiler" cc "$@" -c -Oz -std=c11 -DNDEBUG -DOPJ_STATIC -ffreestanding -fno-builtin \
    -ffunction-sections -fdata-sections -fno-stack-protector -fno-unwind-tables -fstack-size-section \
    -I "$repo_root/probes/photo" -I "$source_dir" \
    "$repo_root/probes/photo/$adapter.c" -o "$destination/photo_$adapter.o"
done
