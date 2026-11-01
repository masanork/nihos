#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
sh "$root/probes/wamr-rv32/run-platform-model.sh"
wamr="$root/build/wamr-2.4.5"
[ "$(git -C "$wamr" rev-parse HEAD)" = 25bd7eb63e828e4bd242cc9b38d260b4b31c6605 ] || { echo 'Run probes/wamr-host/run.sh first' >&2; exit 1; }
[ -z "$(git -C "$wamr" status --porcelain)" ] || { echo 'WAMR source modified' >&2; exit 1; }
table_fix=${NIHOS_WAMR_RV32_TABLE_FIX:-0}
case "$table_fix" in 0|1) ;; *) echo 'NIHOS_WAMR_RV32_TABLE_FIX must be 0 or 1' >&2; exit 1 ;; esac
stack_fix=${NIHOS_WAMR_RV32_STACK_FIX:-0}
case "$stack_fix" in 0|1) ;; *) echo 'NIHOS_WAMR_RV32_STACK_FIX must be 0 or 1' >&2; exit 1 ;; esac
fixes=${NIHOS_WAMR_RV32_FIXES:-0}
case "$fixes" in 0|1) ;; *) echo 'NIHOS_WAMR_RV32_FIXES must be 0 or 1' >&2; exit 1 ;; esac

if [ "$fixes" = 1 ]; then
    lab="$root/build/wamr-rv32-fixes-lab"
    rm -rf "$lab"
    git clone --shared --no-checkout "$wamr" "$lab"
    git -C "$lab" checkout --detach 25bd7eb63e828e4bd242cc9b38d260b4b31c6605
    for p in "$root/probes/wamr-rv32/patches"/000[1-4]-*.patch; do
        git -C "$lab" apply "$p"
    done
    wamr="$lab"
elif [ "$stack_fix" = 1 ]; then
    lab="$root/build/wamr-rv32-stack-lab"
    rm -rf "$lab"
    git clone --shared --no-checkout "$wamr" "$lab"
    git -C "$lab" checkout --detach 25bd7eb63e828e4bd242cc9b38d260b4b31c6605
    git -C "$lab" apply "$root/probes/wamr-rv32/patches/0001-rv32-invokenative-stack-align.patch"
    wamr="$lab"
elif [ "$table_fix" = 1 ]; then
    lab="$root/build/wamr-rv32-table-lab"
    patch="$root/probes/wamr-rv32/patches/table-instance-align-experiment.patch"
    if [ ! -d "$lab/.git" ]; then
        git clone --shared --no-checkout "$wamr" "$lab"
        git -C "$lab" checkout --detach 25bd7eb63e828e4bd242cc9b38d260b4b31c6605
        git -C "$lab" apply "$patch"
    fi
    [ "$(git -C "$lab" rev-parse HEAD)" = 25bd7eb63e828e4bd242cc9b38d260b4b31c6605 ] || exit 1
    git -C "$lab" diff --binary | sed '/^diff --git /d; /^index /d' > "$root/build/wamr-rv32-table-lab.diff"
    cmp -s "$patch" "$root/build/wamr-rv32-table-lab.diff" || { echo 'Table lab patch mismatch' >&2; exit 1; }
    git -C "$lab" diff --cached --quiet || exit 1
    [ -z "$(git -C "$lab" ls-files --others --exclude-standard)" ] || exit 1
    wamr="$lab"
fi
cc=${NIHOS_RISCV_CC:-riscv32-esp-elf-gcc}
command -v "$cc" >/dev/null 2>&1 || { echo 'Set NIHOS_RISCV_CC to riscv32-esp-elf-gcc' >&2; exit 1; }
align_san=${NIHOS_WAMR_RV32_ALIGN_SAN:-0}
case "$align_san" in
  0) out="$root/build/wamr-rv32-compile"; align_flags= ;;
  1) out="$root/build/wamr-rv32-align-compile"; align_flags='-fsanitize=alignment -fno-sanitize-recover=alignment' ;;
  *) echo 'NIHOS_WAMR_RV32_ALIGN_SAN must be 0 or 1' >&2; exit 1 ;;
esac
if [ "$fixes" = 1 ]; then
    if [ "$align_san" = 1 ]; then out="$root/build/wamr-rv32-align-fixes-compile"; else out="$root/build/wamr-rv32-fixes-compile"; fi
elif [ "$stack_fix" = 1 ]; then
    if [ "$align_san" = 1 ]; then out="$root/build/wamr-rv32-align-stack-compile"; else out="$root/build/wamr-rv32-stack-compile"; fi
elif [ "$table_fix" = 1 ]; then
    if [ "$align_san" = 1 ]; then out="$root/build/wamr-rv32-align-table-compile"; else out="$root/build/wamr-rv32-table-compile"; fi
fi
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
