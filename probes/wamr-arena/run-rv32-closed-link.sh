#!/bin/sh
# Symbol closure only: output is not bootable and the two owner hooks are stubs.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
zig=${NIHOS_ZIG:-"$root/.tools/zig-0.17.0/zig"}
[ -x "$zig" ] && [ "$("$zig" version)" = 0.17.0 ] || { echo 'Set NIHOS_ZIG' >&2; exit 1; }
cc=${NIHOS_RISCV_CC:-riscv32-esp-elf-gcc}
cc_path=$(command -v "$cc") || { echo 'Set NIHOS_RISCV_CC' >&2; exit 1; }
prefix=${cc_path%gcc}
[ -x "${prefix}objcopy" ] || { echo 'Missing matching objcopy' >&2; exit 1; }
sh "$root/probes/wamr-arena/run-rv32-inventory.sh"
out="$root/build/wamr-arena-rv32"
"$zig" build-exe -target riscv32-freestanding-none \
  -mcpu=generic_rv32+m+a+c+zicsr+zifencei -O ReleaseSafe -fllvm \
  -fno-stack-check -fno-stack-protector -fno-unwind-tables \
  -fentry=nih_wamr_closed_link_probe \
  "$out/inventory-combined.o" \
  -Mroot="$root/probes/wamr-arena/closed_link_probe.zig" \
  -femit-bin="$out/wamr-closed-link.debug.elf"
undefined=$("${prefix}nm" -u "$out/wamr-closed-link.debug.elf")
[ -z "$undefined" ] || { printf '%s\n' "$undefined" >&2; exit 1; }
"${prefix}objcopy" --strip-debug "$out/wamr-closed-link.debug.elf" "$out/wamr-closed-link.elf"
undefined=$("${prefix}nm" -u "$out/wamr-closed-link.elf")
[ -z "$undefined" ] || { printf '%s\n' "$undefined" >&2; exit 1; }
"${prefix}size" "$out/wamr-closed-link.elf"
echo 'RV32 WAMR symbol closure: no undefined symbols'
