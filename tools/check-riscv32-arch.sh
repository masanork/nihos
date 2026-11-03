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

# Compile coordinator, quarantine guard, controller, and DMA buffer together.
# Credit and register operations are inert; cache uses the CPU0 ROM adapter.
"$zig" build-obj -target "$target" -mcpu="$cpu" \
    -femit-bin="$out_dir/hosted-long-send.o" --dep hosted_long_sender --dep sdio --dep hosted_long_dma_guard --dep hosted_long_cache \
    "-Mroot=$repo_root/tools/probes/hosted-long-send.zig" \
    "-Mhosted_long_sender=$repo_root/src/net/hosted_long_sender.zig" \
    "-Msdio=$repo_root/src/soc/esp32p4/sdio.zig" \
    "-Mhosted_long_dma_guard=$repo_root/src/net/hosted_long_dma_guard.zig" \
    "-Mhosted_long_cache=$repo_root/src/platform/native/hosted_long_cache.zig"

# Link the integrated fixture and audit ROM ABI and SRAM placement.
"$zig" build-obj -target "$target" -mcpu="$cpu" \
    -femit-bin="$out_dir/hosted-long-bus.o" --dep c6_probe --dep hosted_dma_bus --dep hosted_long_cache --dep sdio --dep hosted_long_sender \
    "-Mroot=$repo_root/tools/probes/hosted-long-bus.zig" \
    --dep native_options --dep sdio --dep c6_sdio --dep at_controller --dep timer_group --dep hosted_station \
    "-Mc6_probe=$repo_root/src/platform/native/c6_probe.zig" \
    "-Mhosted_dma_bus=$repo_root/src/net/hosted_dma_bus.zig" \
    "-Mhosted_long_cache=$repo_root/src/platform/native/hosted_long_cache.zig" \
    "-Msdio=$repo_root/src/soc/esp32p4/sdio.zig" \
    "-Mhosted_long_sender=$repo_root/src/net/hosted_long_sender.zig" \
    --dep hosted_long_sender "-Mc6_sdio=$repo_root/tools/probes/hosted-long-pipe.zig" \
    "-Mat_controller=$repo_root/src/net/at_controller.zig" \
    "-Mtimer_group=$repo_root/src/soc/esp32p4/timer_group.zig" \
    "-Mhosted_station=$repo_root/src/net/hosted_station.zig" \
    "-Mnative_options=$out_dir/network-options.zig"

# Link the standalone fixture (stub MMIO/credits) and audit its SRAM layout.
sh "$repo_root/tools/build-hosted-long-link.sh" "$out_dir/hosted-long-link"

# Compile the experimental storage and descriptor path with inert cache ops.
"$zig" build-obj -target "$target" -mcpu="$cpu" \
    -femit-bin="$out_dir/hosted-long-dma.o" --dep hosted_long_dma \
    "-Mroot=$repo_root/tools/probes/hosted-long-dma.zig" \
    "-Mhosted_long_dma=$repo_root/src/net/hosted_long_dma.zig"

# Generate both owner paths without SDK headers, credentials or device access.
# Exporting begin/poll/snapshot through the probe forces codegen of the live
# owner, which the SDK-free qualification images intentionally eliminate.
for diagnostic in false true; do
  for ipv6 in false true; do
    for tcp in false true; do
    printf 'pub const ipv6 = %s;\n' "$ipv6" > "$out_dir/network-config.zig"
    printf 'pub const network_test = %s;\npub const experimental_tcp = %s;\n' "$diagnostic" "$tcp" > "$out_dir/network-options.zig"
    "$zig" build-obj -target "$target" -mcpu="$cpu" \
        -femit-bin="$out_dir/network-$diagnostic-$ipv6-$tcp.o" --dep network_service --dep timer_group \
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
done
echo "Native network owner codegen (normal and diagnostic): ok"

# Compile the separate C6-owned-address, short-only UDP experiment. This is
# codegen only: no device, peer routing policy or DMA behavior is exercised.
printf 'pub const ipv6 = false;\npub const c6_time_offload = true;\npub const udp_smoke_ssid = [_]u8{};\npub const udp_smoke_bssid = [_]u8{0,0,0,0,0,0};\npub const udp_smoke_ip = [_]u8{192,0,2,2};\npub const udp_smoke_mac = [_]u8{2,0,0,0,0,2};\npub const udp_smoke_port: u16 = 44444;\n' > "$out_dir/network-config.zig"
printf 'pub const network_test = false;\npub const experimental_tcp = false;\npub const experimental_udp = true;\npub const experimental_udp_smoke = true;\n' > "$out_dir/network-options.zig"
"$zig" build-obj -target "$target" -mcpu="$cpu" \
    -femit-bin="$out_dir/network-udp-short.o" --dep network_service --dep timer_group \
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
echo "Experimental C6-owned short UDP owner RV32 codegen: ok"
printf 'pub const ipv6 = true;\n' > "$out_dir/network-config.zig"
printf 'pub const network_test = true;\npub const experimental_tcp = true;\n' > "$out_dir/network-options.zig"

# Force TCP owner operations with the exact Hosted station module instance
# used by the native network service. This is codegen, not a linked image.
"$zig" build-obj -target "$target" -mcpu="$cpu" -O ReleaseSafe \
    -femit-bin="$out_dir/hosted-tcp-owner.o" --dep hosted_station \
    "-Mroot=$repo_root/tools/probes/hosted-tcp-owner.zig" \
    "-Mhosted_station=$repo_root/src/net/hosted_station.zig"
echo "Experimental Hosted TCP owner RV32 codegen: ok"

# Force the xy VT bridge against the native Hosted SSH owner. Compile-only.
"$zig" build-obj -target "$target" -mcpu="$cpu" -O ReleaseSafe \
    -femit-bin="$out_dir/ssh-vt-owner.o" --dep hosted_station --dep ssh_terminal_session --dep sqld_layout --dep text_console \
    "-Mroot=$repo_root/tools/probes/ssh-vt-owner.zig" \
    "-Mhosted_station=$repo_root/src/net/hosted_station.zig" \
    "-Msqld_layout=$repo_root/src/platform/native/sqld_layout.zig" \
    --dep view_config --dep canvas "-Mtext_console=$repo_root/src/console.zig" \
    --dep surface "-Mcanvas=$repo_root/src/graphics/canvas.zig" \
    "-Msurface=$repo_root/src/graphics/surface.zig" \
    --dep vt100 --dep terminal_adapter "-Mssh_terminal_session=$repo_root/src/xy/ssh_terminal_session.zig" \
    --dep terminal_adapter "-Mvt100=$repo_root/src/net/vt100.zig" \
    "-Mterminal_adapter=$repo_root/src/net/terminal_adapter.zig" \
    "-Mview_config=$repo_root/src/xy/view_config.zig"
echo "SSH VT and Hosted session RV32 codegen: ok"

# Full native lifecycle type with the same network and model module instances.
# The fixture uses fixed material and is never executed.
"$zig" build-obj -target "$target" -mcpu="$cpu" -O ReleaseSafe \
    -femit-bin="$out_dir/ssh-workspace.o" --dep ssh_workspace \
    "-Mroot=$repo_root/tools/probes/ssh-workspace.zig" \
    --dep network_service --dep text_console --dep ssh_terminal_session --dep ssh_lifecycle \
    "-Mssh_workspace=$repo_root/src/platform/native/ssh_workspace.zig" \
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
    "-Mnetwork_config=$out_dir/network-config.zig" \
    --dep view_config --dep canvas "-Mtext_console=$repo_root/src/console.zig" \
    --dep surface "-Mcanvas=$repo_root/src/graphics/canvas.zig" \
    "-Msurface=$repo_root/src/graphics/surface.zig" \
    --dep vt100 --dep terminal_adapter "-Mssh_terminal_session=$repo_root/src/xy/ssh_terminal_session.zig" \
    --dep terminal_adapter "-Mvt100=$repo_root/src/net/vt100.zig" \
    "-Mterminal_adapter=$repo_root/src/net/terminal_adapter.zig" \
    "-Mview_config=$repo_root/src/xy/view_config.zig" \
    "-Mssh_lifecycle=$repo_root/src/xy/ssh_lifecycle.zig"
echo "Native SSH workspace lifecycle RV32 codegen: ok"

# Fixed compile-only ownership stubs do not authorize hardware execution.
"$zig" build-obj -target "$target" -mcpu="$cpu" -O ReleaseSafe \
    -femit-bin="$out_dir/p4-rng-adc.o" --dep rng_adc \
    "-Mroot=$repo_root/tools/probes/p4-rng-adc.zig" \
    "-Mrng_adc=$repo_root/src/soc/esp32p4/rng_adc.zig"
echo "P4 RNG ADC RV32 codegen: ok (not target execution)"

# Fixed bytes exercise code generation only and must never be used as entropy.
"$zig" build-obj -target "$target" -mcpu="$cpu" -O ReleaseSafe \
    -femit-bin="$out_dir/ssh-entropy.o" --dep ssh_entropy \
    "-Mroot=$repo_root/tools/probes/ssh-entropy.zig" \
    "-Mssh_entropy=$repo_root/src/xy/ssh_entropy.zig"
echo "SSH seeded CSPRNG RV32 codegen: ok (not target execution)"

# This fixed-byte backend is a compile probe only; it does not qualify entropy.
"$zig" build-obj -target "$target" -mcpu="$cpu" -O ReleaseSafe \
    -femit-bin="$out_dir/ssh-seed-collector.o" --dep ssh_seed_collector \
    "-Mroot=$repo_root/tools/probes/ssh-seed-collector.zig" \
    "-Mssh_seed_collector=$repo_root/src/xy/ssh_seed_collector.zig"
echo "SSH seed collector RV32 codegen: ok (not target execution)"

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
