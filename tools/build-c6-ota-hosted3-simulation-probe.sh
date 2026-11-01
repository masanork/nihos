#!/bin/sh
# Build the pinned Hosted 3 candidate P4 simulation fixture. Never opens a device or flashes.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# Explicit one-shot OTA fixture; the build never opens a device.
: "${NIHOS_C6_OTA_IMAGE:?set path to the reviewed C6 app image}"
: "${NIHOS_C6_OTA_SHA256:?set the reviewed C6 app SHA-256}"
[ "$NIHOS_C6_OTA_SHA256" = 04bd14faf943453ccf39075bc61456463b3f362643a3a63dab0f82a53f4dc8fe ] || {
    echo "only the reviewed C6 Hosted 3 candidate digest is allowed" >&2
    exit 1
}
NIHOS_C6_PROTOCOL=hosted
umask 077
build_dir="$repo_root/build/c6-ota-hosted3-simulation-probe"
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
"$python" "$repo_root/tools/prepare-c6-ota-map.py" "$NIHOS_C6_OTA_IMAGE" "$NIHOS_C6_OTA_SHA256" "$build_dir"
(cd "$build_dir" && "$zig" cc -c -target riscv32-freestanding-none -mcpu=generic_rv32+m+a+c+zicsr+zifencei -mabi=ilp32 ota-image.S -o ota-image.o)
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
    -fentry=nih_native_start -T "$repo_root/probes/c6-sdio/esp32p4-ota-update.ld" --gc-sections \
    "$repo_root/probes/c6-sdio/start.S" "$build_dir/pads.o" "$build_dir/ota-image.o" \
    --dep c6_probe --dep timer_group --dep wifi_config -Mroot="$repo_root/probes/c6-sdio/ota-hosted3-simulation-main.zig" \
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
"$python" "$repo_root/tools/check-c6-ota-map.py" "$build_dir/nihos-c6-probe.elf" \
    "$build_dir/nihos-c6-probe.bin" "$build_dir/candidate.bin" "$NIHOS_C6_OTA_SHA256" "$build_dir/image-audit.json" update
echo "C6 Hosted 3 OTA simulation fixture is build-only; no device was accessed."
"$python" - "$repo_root" "$build_dir" <<'PY'
import hashlib, json, subprocess, sys
from pathlib import Path
root, build = map(Path, sys.argv[1:])
names = [
    'probes/c6-sdio/ota-hosted3-simulation-main.zig', 'probes/c6-sdio/start.S',
    'probes/c6-sdio/pads.c', 'probes/c6-sdio/esp32p4-ota-update.ld',
    'src/platform/native/c6_probe.zig', 'src/soc/esp32p4/sdio.zig',
    'src/soc/esp32p4/timer_group.zig', 'src/net/c6_sdio.zig',
    'src/net/hosted.zig', 'src/net/hosted_station.zig', 'src/net/hosted_ota.zig',
    'src/net/hosted_ota_session.zig', 'src/net/hosted_ota_pump.zig',
    'src/net/hosted_ota_guard.zig', 'src/net/hosted_ota_arm.zig',
    'src/net/hosted_ota_fake.zig', 'tools/build-c6-ota-hosted3-simulation-probe.sh',
    'tools/prepare-c6-ota-map.py', 'tools/check-c6-ota-map.py',
]
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
receipt = {
    'schema': 1,
    'scope': 'P4 in-memory OTA simulation; physical C6 writes forbidden',
    'revision': subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip(),
    'dirty': bool(subprocess.check_output(['git', '-C', str(root), 'status', '--porcelain'], text=True).strip()),
    'sources': {name: digest(root / name) for name in names},
    'artifacts': {name: digest(build / name) for name in (
        'candidate.bin', 'nihos-c6-probe.elf', 'nihos-c6-probe.bin', 'image-audit.json',
        'loader/bootloader/bootloader.bin', 'loader/partition_table/partition-table.bin', 'loader/sdkconfig',
    )},
}
(build / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
print('P4 simulation source/artifact receipt:', build / 'receipt.json')
PY
