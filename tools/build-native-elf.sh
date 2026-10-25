#!/bin/sh
# No ESP-IDF installation is needed to compile/link the native application.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
profile=${1:-device}
case "$profile" in
    device) rev3=0 ;;
    emulator) rev3=1 ;;
    *) echo "usage: $0 [device|emulator] [output-directory] [integer|floating]" >&2; exit 1 ;;
esac
build_dir=${2:-"$repo_root/build/native-$profile"}
mode=${3:-integer}
case "$mode" in
    integer) floating=false; fp_asm=0 ;;
    floating) floating=true; fp_asm=1 ;;
    *) echo "mode must be integer or floating" >&2; exit 1 ;;
esac
zig="$repo_root/.tools/zig-0.17.0/zig"
if [ ! -x "$zig" ]; then sh "$repo_root/tools/bootstrap-zig.sh" >/dev/null; fi
mkdir -p "$build_dir"
printf 'pub const floating = %s;\n' "$floating" > "$build_dir/native_options.zig"
set --
if [ "$mode" = floating ]; then
    "$zig" cc -c -target riscv32-freestanding-none \
        -mcpu=generic_rv32+m+a+c+f+zicsr+zifencei -mabi=ilp32 -I "$repo_root/src/kernel" \
        -o "$build_dir/fpu.o" "$repo_root/src/arch/riscv32/fpu.S"
    set -- "$build_dir/fpu.o"
fi
"$zig" build-exe -target riscv32-freestanding-none \
    -mcpu=generic_rv32+m+a+c+zicsr+zifencei -O safe -fllvm -fno-strip \
    -fno-stack-check -fno-stack-protector -fno-unwind-tables \
    -fentry=nih_native_start -T "$repo_root/src/platform/native/esp32p4.ld" \
    -DNIH_NATIVE_REV3="$rev3" -DNIH_NATIVE_FLOATING="$fp_asm" --gc-sections \
    -I "$repo_root/src/arch/riscv32" -I "$repo_root/src/kernel" \
    "$repo_root/src/platform/native/start.S" "$@" \
    -target riscv32-freestanding-none -mcpu=generic_rv32+m+a+c+zicsr+zifencei -O safe \
    --dep timer_group --dep native_tasks -Mroot="$repo_root/src/platform/native/main.zig" \
    -target riscv32-freestanding-none -mcpu=generic_rv32+m+a+c+zicsr+zifencei -O safe \
    -Mtimer_group="$repo_root/src/soc/esp32p4/timer_group.zig" \
    -target riscv32-freestanding-none -mcpu=generic_rv32+m+a+c+zicsr+zifencei -O safe \
    --dep scheduler --dep task_control --dep tick_clock --dep timer_group \
    --dep remote_events --dep spsc_ring --dep software_ipi --dep park --dep native_options \
    -Mnative_tasks="$repo_root/src/arch/riscv32/native_tasks.zig" \
    -target riscv32-freestanding-none -mcpu=generic_rv32+m+a+c+zicsr+zifencei -O safe \
    -Mscheduler="$repo_root/src/kernel/scheduler.zig" \
    -target riscv32-freestanding-none -mcpu=generic_rv32+m+a+c+zicsr+zifencei -O safe \
    -Mtask_control="$repo_root/src/kernel/task_control.zig" \
    -target riscv32-freestanding-none -mcpu=generic_rv32+m+a+c+zicsr+zifencei -O safe \
    -Mtick_clock="$repo_root/src/kernel/tick_clock.zig" \
    -target riscv32-freestanding-none -mcpu=generic_rv32+m+a+c+zicsr+zifencei -O safe \
    -Mremote_events="$repo_root/src/kernel/remote_events.zig" \
    -target riscv32-freestanding-none -mcpu=generic_rv32+m+a+c+zicsr+zifencei -O safe \
    -Mspsc_ring="$repo_root/src/kernel/spsc_ring.zig" \
    -target riscv32-freestanding-none -mcpu=generic_rv32+m+a+c+zicsr+zifencei -O safe \
    -Msoftware_ipi="$repo_root/src/soc/esp32p4/software_ipi.zig" \
    -target riscv32-freestanding-none -mcpu=generic_rv32+m+a+c+zicsr+zifencei -O safe \
    -Mpark="$repo_root/src/kernel/park.zig" \
    -Mnative_options="$build_dir/native_options.zig" \
    -femit-bin="$build_dir/nihos-native.elf"
