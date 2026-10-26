#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
python3 "$repo_root/tools/native_image_test.py"
zig=$(sh "$repo_root/tools/bootstrap-zig.sh")
out_dir=$(mktemp -d "${TMPDIR:-/tmp}/nihos-riscv32-check.XXXXXX")
trap 'rm -rf "$out_dir"' EXIT HUP INT TERM

target=riscv32-freestanding-none
cpu=generic_rv32+m+a+c+f+zicsr+zifencei

"$zig" build-obj -target "$target" -mcpu="$cpu" \
    -femit-bin="$out_dir/c6-at.o" --dep esp_at \
    "-Mroot=$repo_root/tools/probes/c6-at.zig" \
    "-Mesp_at=$repo_root/src/net/esp_at.zig"

"$zig" build-obj -target "$target" -mcpu="$cpu" \
    -femit-bin="$out_dir/context.o" \
    "$repo_root/src/arch/riscv32/context.zig"
"$zig" build-obj -target "$target" -mcpu="$cpu" \
    -femit-bin="$out_dir/trap.o" \
    "$repo_root/src/arch/riscv32/trap.zig"
"$zig" build-obj -target "$target" -mcpu="$cpu" \
    -femit-bin="$out_dir/native_trap.o" \
    --dep timer_group \
    --dep scheduler \
    --dep tick_clock \
    --dep task_control \
    --dep spsc_ring \
    --dep spsc_channel \
    --dep remote_events \
    --dep software_ipi \
    --dep park \
    "-Mroot=$repo_root/src/arch/riscv32/native_trap.zig" \
    "-Mtimer_group=$repo_root/src/soc/esp32p4/timer_group.zig" \
    "-Mscheduler=$repo_root/src/kernel/scheduler.zig" \
    "-Mtick_clock=$repo_root/src/kernel/tick_clock.zig" \
    "-Mtask_control=$repo_root/src/kernel/task_control.zig" \
    "-Mspsc_ring=$repo_root/src/kernel/spsc_ring.zig" \
    "-Mspsc_channel=$repo_root/src/kernel/spsc_channel.zig" \
    "-Mremote_events=$repo_root/src/kernel/remote_events.zig" \
    "-Msoftware_ipi=$repo_root/src/soc/esp32p4/software_ipi.zig" \
    "-Mpark=$repo_root/src/kernel/park.zig"
"$zig" cc -c -target "$target" -mcpu="$cpu" \
    -I "$repo_root/src/arch/riscv32" \
    -I "$repo_root/src/kernel" \
    -o "$out_dir/trap_entry.o" \
    "$repo_root/src/arch/riscv32/trap_entry.S"
"$zig" cc -c -target "$target" -mcpu="$cpu" \
    -I "$repo_root/src/kernel" \
    -o "$out_dir/fpu.o" \
    "$repo_root/src/arch/riscv32/fpu.S"

for profile in device emulator; do
    for mode in integer floating compiled; do
        native_dir="$out_dir/native-$profile-$mode"
        sh "$repo_root/tools/build-native-elf.sh" "$profile" "$native_dir" "$mode"
        python3 "$repo_root/tools/check-native-image.py" "$native_dir/nihos-native.elf" \
            --elf-only "$native_dir/code-audit.json" "$mode" "$profile"
    done
done

echo "RV32 architecture contract and six audited native ELF links: ok"
