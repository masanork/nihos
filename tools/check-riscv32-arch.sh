#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
python3 "$repo_root/tools/native_image_test.py"
python3 "$repo_root/tools/c6_image_test.py"
zig=$(sh "$repo_root/tools/bootstrap-zig.sh")
out_dir=$(mktemp -d "${TMPDIR:-/tmp}/nihos-riscv32-check.XXXXXX")
trap 'rm -rf "$out_dir"' EXIT HUP INT TERM

target=riscv32-freestanding-none
cpu=generic_rv32+m+a+c+f+zicsr+zifencei

"$zig" build-obj -target "$target" -mcpu="$cpu" \
    -femit-bin="$out_dir/c6-at.o" --dep at_controller \
    "-Mroot=$repo_root/tools/probes/c6-at.zig" \
    "-Mat_controller=$repo_root/src/net/at_controller.zig"

printf 'pub const normal_storage = false;\n' > "$out_dir/network-options.zig"
"$zig" build-obj -target "$target" -mcpu="$cpu" \
    -femit-bin="$out_dir/c6-sdio.o" --dep c6_probe --dep timer_group \
    "-Mroot=$repo_root/tools/probes/c6-sdio.zig" \
    --dep native_options --dep sdio --dep c6_sdio --dep at_controller --dep timer_group --dep hosted_station \
    "-Mc6_probe=$repo_root/src/platform/native/c6_probe.zig" \
    "-Msdio=$repo_root/src/soc/esp32p4/sdio.zig" \
    "-Mc6_sdio=$repo_root/src/net/c6_sdio.zig" \
    "-Mat_controller=$repo_root/src/net/at_controller.zig" \
    "-Mhosted_station=$repo_root/src/net/hosted_station.zig" \
    "-Mtimer_group=$repo_root/src/soc/esp32p4/timer_group.zig" \
    "-Mnative_options=$out_dir/network-options.zig"

# Generate both owner paths without SDK headers, credentials or device access.
# Exporting begin/poll/snapshot through the probe forces codegen of the live
# owner, which the SDK-free qualification images intentionally eliminate.
for diagnostic in false true; do
  for ipv6 in false true; do
    printf 'pub const ipv6 = %s;\n' "$ipv6" > "$out_dir/network-config.zig"
    printf 'pub const network_test = %s;\n' "$diagnostic" > "$out_dir/network-options.zig"
    "$zig" build-obj -target "$target" -mcpu="$cpu" \
        -femit-bin="$out_dir/network-$diagnostic-$ipv6.o" --dep network_service --dep timer_group \
        "-Mroot=$repo_root/tools/probes/network-service.zig" \
        --dep native_options --dep network_config --dep timer_group --dep c6_probe --dep sdio --dep c6_sdio --dep hosted_station \
        "-Mnetwork_service=$repo_root/src/platform/native/network_service.zig" \
        --dep native_options --dep sdio --dep c6_sdio --dep at_controller --dep timer_group --dep hosted_station \
        "-Mc6_probe=$repo_root/src/platform/native/c6_probe.zig" \
        "-Msdio=$repo_root/src/soc/esp32p4/sdio.zig" \
        "-Mc6_sdio=$repo_root/src/net/c6_sdio.zig" \
        "-Mat_controller=$repo_root/src/net/at_controller.zig" \
        "-Mhosted_station=$repo_root/src/net/hosted_station.zig" \
        "-Mtimer_group=$repo_root/src/soc/esp32p4/timer_group.zig" \
        "-Mnative_options=$out_dir/network-options.zig" \
        "-Mnetwork_config=$out_dir/network-config.zig"
  done
done
echo "Native network owner codegen (normal and diagnostic): ok"

"$zig" build-obj -target "$target" -mcpu="$cpu" \
    -femit-bin="$out_dir/rtc.o" --dep tab5_rtc \
    "-Mroot=$repo_root/tools/probes/rtc.zig" \
    "-Mtab5_rtc=$repo_root/src/board/tab5/rtc.zig"

"$zig" build-obj -target "$target" -mcpu="$cpu" \
    -femit-bin="$out_dir/bmi270.o" --dep tab5_bmi270 \
    "-Mroot=$repo_root/tools/probes/bmi270.zig" \
    "-Mtab5_bmi270=$repo_root/src/board/tab5/bmi270.zig"

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
