#!/bin/sh
# Build the P4-side CPU0-only SDIO/AT fixture. Never opens a device or flashes.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
build_dir="$repo_root/build/c6-sdio-probe"
if [ "${NIHOS_C6_LONG_DMA:-0}" != 0 ] &&
   { [ "${NIHOS_C6_LONG_DMA:-0}" != 1 ] || [ "${NIHOS_C6_PROTOCOL:-at}" != hosted ]; }; then
    echo "Long DMA diagnostic requires NIHOS_C6_LONG_DMA=1 and NIHOS_C6_PROTOCOL=hosted" >&2
    exit 1
fi
if [ -n "${NIHOS_C6_WIFI_CONFIG:-}" ]; then
    # Private credentials and images never share the public AT-only directory.
    umask 077
    build_dir="$repo_root/build/c6-wifi-probe"
fi
if [ "${NIHOS_C6_PROTOCOL:-at}" = hosted ]; then
    umask 077
    build_dir="$repo_root/build/c6-hosted-probe"
    if [ "${NIHOS_C6_IPV6:-0}" = 1 ]; then build_dir="$repo_root/build/c6-ipv6-probe"; fi
    if [ "${NIHOS_C6_LONG_DMA:-0}" = 1 ]; then build_dir="$repo_root/build/c6-hosted-long-probe"; fi
fi
c6_sdk=${NIHOS_IDF_PATH:-"$HOME/esp32/esp-idf-v5.4.4"}
if [ ! -f "$c6_sdk/export.sh" ] ||
   [ "$(git -C "$c6_sdk" rev-parse HEAD)" != "$(git -C "$c6_sdk" rev-parse 'v5.4.4^{commit}')" ] ||
   [ -n "$(git -C "$c6_sdk" diff --name-only -- components/hal components/soc)" ]; then
    echo "C6 fixture requires pinned ESP-IDF v5.4.4 with unmodified LL definitions" >&2
    exit 1
fi
zig=$(sh "$repo_root/tools/bootstrap-zig.sh")
# Use a separate generated configuration, not the C6 SDK's Python environment.
# shellcheck disable=SC1091
. "$c6_sdk/export.sh" >/dev/null
python=${NIHOS_IDF_PYTHON:-python}
mkdir -p "$build_dir"
"$python" - "$repo_root/probes/c6-sdio/esp32p4.ld" "$build_dir/probe.ld" "${NIHOS_C6_LONG_DMA:-0}" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
if sys.argv[3] == '1':
    for symbol in ('__stack1_top', '__irq_stack1_top'):
        old = '. += 8192; ' + symbol
        if text.count(old) != 1:
            raise SystemExit('C6 linker stack template changed')
        text = text.replace(old, '. += 0; ' + symbol)
    text = '/* Long DMA profile: CPU1 parked; no private CPU1 stacks. */\n' + text
Path(sys.argv[2]).write_text(text)
PY
"$python" "$repo_root/tools/c6-wifi-config.py" "$build_dir/wifi-config.zig" "${NIHOS_C6_WIFI_CONFIG:-}" "${NIHOS_C6_PROTOCOL:-at}"
idf.py -C "$repo_root/ports/esp32p4-native" -B "$build_dir/loader" \
    -D IDF_TARGET=esp32p4 -D "SDKCONFIG=$build_dir/loader/sdkconfig" \
    -D "SDKCONFIG_DEFAULTS=$repo_root/ports/esp32p4-native/sdkconfig.defaults" bootloader partition-table \
    > "$build_dir/loader-build.log" 2>&1
cpu=generic_rv32+m+a+c+zicsr+zifencei
headers="$repo_root/.tools/zig-0.17.0/lib/libc/include"
"$zig" cc -c -target riscv32-freestanding-none -mcpu="$cpu" -mabi=ilp32 \
    -O2 -std=gnu17 -ffreestanding -fno-builtin -fno-pic \
    -isystem "$headers/riscv32-linux-musl" -isystem "$headers/generic-musl" \
    -isystem "$headers/riscv-linux-any" -I "$build_dir/loader/config" \
    -I "$c6_sdk/components/hal/include" -I "$c6_sdk/components/hal/platform_port/include" \
    -I "$c6_sdk/components/hal/esp32p4/include" -I "$c6_sdk/components/soc/include" \
    -I "$c6_sdk/components/soc/esp32p4/include" -I "$c6_sdk/components/soc/esp32p4/register/hw_ver1" \
    -I "$c6_sdk/components/esp_common/include" -I "$c6_sdk/components/esp_hw_support/include" \
    -I "$c6_sdk/components/esp_rom/include" -I "$c6_sdk/components/esp_rom/esp32p4/include" \
    -I "$c6_sdk/components/esp_rom/esp32p4" \
    -o "$build_dir/pads.o" "$repo_root/probes/c6-sdio/pads.c"
printf 'pub const normal_storage = false;\n' > "$build_dir/c6-options.zig"
"$zig" build-exe -target riscv32-freestanding-none -mcpu="$cpu" -O safe -fllvm -fno-strip \
    -fno-stack-check -fno-stack-protector -fno-unwind-tables \
    -fentry=nih_native_start -T "$build_dir/probe.ld" --gc-sections \
    "$repo_root/probes/c6-sdio/start.S" "$build_dir/pads.o" \
    --dep c6_probe --dep timer_group --dep wifi_config --dep long_dma -Mroot="$repo_root/probes/c6-sdio/main.zig" \
    --dep hosted_dma_bus --dep hosted_long_cache --dep hosted_station -Mlong_dma="$repo_root/probes/hosted-long-send/boot-bus.zig" \
    -Mhosted_dma_bus="$repo_root/src/net/hosted_dma_bus.zig" \
    -Mhosted_long_cache="$repo_root/src/platform/native/hosted_long_cache.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mwifi_config="$build_dir/wifi-config.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    --dep native_options --dep sdio --dep c6_sdio --dep at_controller --dep timer_group --dep hosted_station -Mc6_probe="$repo_root/src/platform/native/c6_probe.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mhosted_station="$repo_root/src/net/hosted_station.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Msdio="$repo_root/src/soc/esp32p4/sdio.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mnative_options="$build_dir/c6-options.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mc6_sdio="$repo_root/src/net/c6_sdio.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mat_controller="$repo_root/src/net/at_controller.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mtimer_group="$repo_root/src/soc/esp32p4/timer_group.zig" \
    -femit-bin="$build_dir/nihos-c6-probe.elf"
"$python" -m esptool --chip esp32p4 elf2image \
    --flash_mode dio --flash_freq 80m --flash_size 16MB \
    --min-rev-full 100 --max-rev-full 299 --elf-sha256-offset 0xb0 \
    -o "$build_dir/nihos-c6-probe.bin" "$build_dir/nihos-c6-probe.elf"
"$python" "$repo_root/tools/check-c6-sdio-image.py" "$build_dir/nihos-c6-probe.elf" \
    "$build_dir/nihos-c6-probe.bin" "$build_dir/image-audit.json" "${NIHOS_C6_PROTOCOL:-at}"
"$python" - "$repo_root" "$build_dir" "$c6_sdk" <<'PY'
import hashlib, json, subprocess, sys
from pathlib import Path
root, dest, sdk = map(Path, sys.argv[1:])
names = [
    'probes/c6-sdio/start.S', 'probes/c6-sdio/main.zig', 'probes/c6-sdio/pads.c',
    'src/platform/native/c6_probe.zig', 'probes/c6-sdio/esp32p4.ld',
    'src/soc/esp32p4/sdio.zig', 'src/soc/esp32p4/timer_group.zig',
    'src/net/c6_sdio.zig', 'src/net/esp_at.zig', 'src/net/at_commands.zig',
    'src/net/at_controller.zig', 'tools/build-c6-sdio-probe.sh',
    'src/net/wifi_station.zig', 'tools/c6-wifi-config.py',
    'src/net/hosted.zig', 'src/net/hosted_station.zig', 'src/net/hosted_diagnostics.zig', 'src/net/dhcp.zig',
    'src/net/ipv6.zig',
    'probes/hosted-long-send/boot-bus.zig', 'src/net/hosted_dma_bus.zig',
    'src/net/hosted_long_dma.zig', 'src/platform/native/hosted_long_cache.zig',
    'src/net/hosted_tx_plan.zig', 'src/net/long_udp_probe.zig',
    'tools/check-c6-sdio-image.py', 'tools/check-c6-sram-boundary.py', 'tools/c6_image_test.py',
]
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
def git(path, *args):
    return subprocess.check_output(['git', '-C', str(path), *args], text=True).strip()
report = {
    'schema': 1, 'scope': 'P4 native C6 boot fixture build only; no device execution',
    'nihos': git(root, 'rev-parse', 'HEAD'),
    'nihos_dirty': bool(git(root, 'status', '--porcelain')),
    'p4_sdk': git(sdk, 'rev-parse', 'HEAD'), 'p4_sdk_dirty': bool(git(sdk, 'status', '--porcelain')),
    'sources': {name: sha(root / name) for name in names},
    'artifacts': {name: sha(dest / name) for name in [
        'nihos-c6-probe.elf', 'nihos-c6-probe.bin', 'image-audit.json', 'loader/sdkconfig', 'probe.ld',
        'loader/bootloader/bootloader.bin', 'loader/partition_table/partition-table.bin',
    ]},
    'peer_assumptions': {'receive_buffer_bytes': 1536 if dest.name in ('c6-hosted-probe', 'c6-hosted-long-probe', 'c6-ipv6-probe') else 512,
                         'credit_limit': 64 if dest.name in ('c6-hosted-probe', 'c6-hosted-long-probe', 'c6-ipv6-probe') else 10, 'fresh_reset_required': True},
    'protocol': 'hosted' if dest.name in ('c6-hosted-probe', 'c6-hosted-long-probe', 'c6-ipv6-probe') else 'at',
    'long_dma_enabled': dest.name == 'c6-hosted-long-probe',
    'udp_probe_enabled': 'pub const udp_enabled = true;' in (dest / 'wifi-config.zig').read_text(),
    'ipv6_enabled': 'pub const ipv6 = true;' in (dest / 'wifi-config.zig').read_text(),
    'wifi_enabled': dest.name != 'c6-sdio-probe',
    'private_artifacts': dest.name != 'c6-sdio-probe',
}
(dest / 'receipt.json').write_text(json.dumps(report, indent=2) + '\n')
print('P4 C6 fixture source/artifact receipt:', dest / 'receipt.json')
PY
