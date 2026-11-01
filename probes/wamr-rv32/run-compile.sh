#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
sh "$root/probes/wamr-rv32/run-platform-model.sh"
wamr="$root/build/wamr-2.4.5"
[ "$(git -C "$wamr" rev-parse HEAD)" = 25bd7eb63e828e4bd242cc9b38d260b4b31c6605 ] || { echo 'Run probes/wamr-host/run.sh first' >&2; exit 1; }
[ -z "$(git -C "$wamr" status --porcelain)" ] || { echo 'WAMR source modified' >&2; exit 1; }
cc=${NIHOS_RISCV_CC:-riscv32-esp-elf-gcc}
command -v "$cc" >/dev/null 2>&1 || { echo 'Set NIHOS_RISCV_CC to riscv32-esp-elf-gcc' >&2; exit 1; }
align_san=${NIHOS_WAMR_RV32_ALIGN_SAN:-0}
case "$align_san" in
  0) out="$root/build/wamr-rv32-compile"; align_flags= ;;
  1) out="$root/build/wamr-rv32-align-compile"; align_flags='-fsanitize=alignment -fno-sanitize-recover=alignment' ;;
  *) echo 'NIHOS_WAMR_RV32_ALIGN_SAN must be 0 or 1' >&2; exit 1 ;;
esac
cmake -S "$root/probes/wamr-rv32" -B "$out" \
 -DWAMR_ROOT_DIR="$wamr" -DCMAKE_SYSTEM_NAME=Generic -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
 -DCMAKE_C_COMPILER="$cc" -DCMAKE_ASM_COMPILER="$cc" -DCMAKE_BUILD_TYPE=Release \
 "-DCMAKE_C_FLAGS=-ffreestanding -fno-unwind-tables -fno-asynchronous-unwind-tables -march=rv32imac_zicsr_zifencei -mabi=ilp32 $align_flags" \
 '-DCMAKE_ASM_FLAGS=-march=rv32imac_zicsr_zifencei -mabi=ilp32'
cmake --build "$out" --parallel 4

cc_path=$(command -v "$cc")
tool_prefix=${cc_path%gcc}
[ -x "${tool_prefix}ld" ] && [ -x "${tool_prefix}nm" ] && [ -x "${tool_prefix}size" ] || { echo 'Missing matching binutils' >&2; exit 1; }
combined="$out/wamr-combined.o"
"${tool_prefix}ld" -m elf32lriscv -r --whole-archive "$out/libwamr-rv32-compile.a" --no-whole-archive -o "$combined"
"${tool_prefix}nm" -u "$combined" > "$out/undefined.txt"
"${tool_prefix}size" "$combined"
printf 'Compile-only RV32 object; unresolved imports: %s\n' "$out/undefined.txt"
