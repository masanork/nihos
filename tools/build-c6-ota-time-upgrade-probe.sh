#!/bin/sh
# Build the pinned 1.4.1 -> 2.13.1 P4 fixture. Never opens a device or flashes.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# Explicit one-shot OTA fixture; the build never opens a device.
: "${NIHOS_C6_OTA_IMAGE:?set path to the reviewed C6 app image}"
: "${NIHOS_C6_OTA_SHA256:?set the reviewed C6 app SHA-256}"
[ "$NIHOS_C6_OTA_SHA256" = 7f036e616df4d4782015caf30f185f7859af115438f394463600d0f8d69995be ] || {
    echo "only the reviewed C6 time candidate digest is allowed" >&2
    exit 1
}
NIHOS_C6_PROTOCOL=hosted
umask 077
build_dir="$repo_root/build/c6-ota-time-upgrade-probe"
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
    --dep c6_probe --dep timer_group --dep wifi_config -Mroot="$repo_root/probes/c6-sdio/ota-time-upgrade-main.zig" \
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
echo "C6 OTA time-upgrade fixture is build-only; no device was accessed."
