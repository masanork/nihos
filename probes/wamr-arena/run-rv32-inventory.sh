#!/bin/sh
# Reachability inventory only. The produced relocatable has undefined symbols.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
zig=${NIHOS_ZIG:-"$root/.tools/zig-0.17.0/zig"}
[ -x "$zig" ] && [ "$("$zig" version)" = 0.17.0 ] || { echo 'Set NIHOS_ZIG' >&2; exit 1; }
cc=${NIHOS_RISCV_CC:-riscv32-esp-elf-gcc}
cc_path=$(command -v "$cc") || { echo 'Set NIHOS_RISCV_CC' >&2; exit 1; }
prefix=${cc_path%gcc}
for t in ld nm size; do [ -x "$prefix$t" ] || { echo 'Missing matching binutils' >&2; exit 1; }; done
out="$root/build/wamr-arena-rv32"
# Rebuild both sides from the verified source before inventorying symbols.
sh "$root/probes/wamr-rv32/run-compile.sh"
sh "$root/probes/wamr-arena/run-rv32.sh"
"$cc_path" -std=c11 -Os -ffreestanding -ffunction-sections -fdata-sections -march=rv32imac_zicsr_zifencei -mabi=ilp32 \
 -I"$root/build/wamr-2.4.5/core/iwasm/include" -c "$root/probes/wamr-arena/rv32_link_inventory.c" -o "$out/inventory.o"
for source in c_sort c_format c_strings; do
    extra=
    if [ "$source" = c_strings ]; then extra=-DNIH_C_NO_FABS; fi
    "$zig" cc -c -target riscv32-freestanding-none -mcpu=generic_rv32+m+a+c+zicsr+zifencei -mabi=ilp32 \
      -Oz -std=c11 -ffreestanding -fno-builtin -fno-unwind-tables -fno-asynchronous-unwind-tables -ffunction-sections -fdata-sections \
      -I"$root/include" $extra "$root/src/compat/$source.c" -o "$out/$source.o"
done
"${prefix}ld" -m elf32lriscv -r --gc-sections -e nih_wamr_rv32_link_inventory \
 "$out/inventory.o" "$out/arena.o" "$out/c_sort.o" "$out/c_format.o" "$out/c_strings.o" \
 "$root/build/wamr-rv32-compile/libwamr-rv32-compile.a" -o "$out/inventory-combined.o"
"${prefix}nm" -u "$out/inventory-combined.o" > "$out/undefined-reachable.txt"
"${prefix}size" "$out/inventory-combined.o"
printf 'Reachable compile-only undefined symbols: %s\n' "$out/undefined-reachable.txt"
