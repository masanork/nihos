#!/bin/sh
# Build an independent SRAM application; ESP-IDF supplies only boot artifacts.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
profile=${1:-device}
case "$profile" in
    device) revision=100; max_revision=299 ;;
    emulator) revision=300; max_revision=399 ;;
    *) echo "usage: $0 [device|emulator] [integer|floating|compiled|sqlite]" >&2; exit 1 ;;
esac
mode=${2:-integer}
# The public device build is the normal interactive OS. Low-level ELF builds
# and explicitly selected display/qualification/storage profiles remain fixtures.
if [ "$profile" = device ] && [ "$mode" = integer ] && [ "${NIHOS_NATIVE_QUALIFICATION:-0}" = 0 ] && [ "${NIHOS_NATIVE_SDMMC:-0}" = 0 ] && [ "${NIHOS_NATIVE_BOOT_FAST:-auto}" != 0 ] && [ "${NIHOS_NATIVE_DISPLAY:-2}" = 2 ] && [ "${NIHOS_NATIVE_CONSOLE:-1}" = 1 ] && [ "${NIHOS_NATIVE_CONSOLE_LIVE:-1}" = 1 ] && [ "${NIHOS_NATIVE_PSRAM_200:-1}" = 1 ]; then
    export NIHOS_NATIVE_DISPLAY="${NIHOS_NATIVE_DISPLAY:-2}"
    export NIHOS_NATIVE_PSRAM_200="${NIHOS_NATIVE_PSRAM_200:-1}"
    export NIHOS_NATIVE_CONSOLE="${NIHOS_NATIVE_CONSOLE:-1}"
    export NIHOS_NATIVE_CONSOLE_LIVE="${NIHOS_NATIVE_CONSOLE_LIVE:-1}"
    export NIHOS_NATIVE_NETWORK="${NIHOS_NATIVE_NETWORK:-1}"
    # Explicit fixture builds retain their historical single-device profile.
    if [ "${NIHOS_NATIVE_AUDIO:-0}${NIHOS_NATIVE_MICROPHONE:-0}${NIHOS_NATIVE_RS485:-0}" = 000 ] && [ "${NIHOS_NATIVE_BOOT_TEST:-0}" = 0 ]; then
        export NIHOS_NATIVE_DEVICES="${NIHOS_NATIVE_DEVICES:-1}"
        if [ "${NIHOS_NATIVE_USB:-0}" = 0 ]; then
            export NIHOS_NATIVE_NORMAL_STORAGE="${NIHOS_NATIVE_NORMAL_STORAGE:-1}"
            if [ "${NIHOS_NATIVE_DEVICES:-0}" = 1 ] && [ "${NIHOS_NATIVE_PMP_PROBE:-0}" = 0 ] && [ "${NIHOS_NATIVE_CAMERA_ID+x}" != x ]; then
                export NIHOS_NATIVE_CAMERA_ID=1
                export NIHOS_NATIVE_CAMERA_DIAGNOSTICS="${NIHOS_NATIVE_CAMERA_DIAGNOSTICS:-0}"
            fi
        fi
    fi
fi
build_dir="$repo_root/build/native-$profile"
if [ "${NIHOS_NATIVE_NETWORK:-0}" = 1 ]; then
    umask 077
    build_dir="$build_dir-network"
fi
if [ "${NIHOS_NATIVE_AUDIO:-0}" = 1 ]; then build_dir="$build_dir-audio"; fi
if [ "${NIHOS_NATIVE_MICROPHONE:-0}" = 1 ]; then build_dir="$build_dir-microphone"; fi
if [ "${NIHOS_NATIVE_RS485:-0}" = 1 ]; then build_dir="$build_dir-rs485"; fi
if [ "${NIHOS_NATIVE_DEVICES:-0}" = 1 ]; then build_dir="$build_dir-devices"; fi
if [ "${NIHOS_NATIVE_PMP_PROBE:-0}" = 1 ]; then build_dir="$build_dir-pmp-probe"; fi
if [ "${NIHOS_NATIVE_CAMERA_ID:-0}" = 1 ]; then
    if [ "${NIHOS_NATIVE_CAMERA_DIAGNOSTICS:-1}" = 1 ]; then build_dir="$build_dir-camera-id"; else build_dir="$build_dir-camera"; fi
fi
if [ "${NIHOS_NATIVE_CAMERA_UI_FIXTURE:-0}" = 1 ]; then build_dir="$build_dir-camera-ui-fixture"; fi
boot_dir="$build_dir/loader"
case "$mode" in
    integer) ;;
    floating|compiled|sqlite|graphics) build_dir="$build_dir-$mode" ;;
    *) echo "mode must be integer, floating, compiled, sqlite or graphics" >&2; exit 1 ;;
esac
if [ "$mode" = graphics ]; then boot_dir="$build_dir/loader"; fi
native_sdk=${NIHOS_IDF_PATH:-${IDF_PATH:-"$HOME/esp32/esp-idf-v5.4.4"}}
if [ ! -f "$native_sdk/export.sh" ]; then
    echo "ESP-IDF v5.4.4 not found; set NIHOS_IDF_PATH" >&2
    exit 1
fi
if ! command -v idf.py >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "$native_sdk/export.sh" >/dev/null
fi
python=${NIHOS_IDF_PYTHON:-python}
mkdir -p "$build_dir"
# A failed rebuild must not expose an older image/audit as current output.
rm -f "$build_dir/image-audit.json" "$build_dir/nihos-native.bin" "$build_dir/nihos-native-flash.bin"
defaults="$repo_root/ports/esp32p4-native/sdkconfig.defaults"
if [ "$profile" = emulator ]; then
    defaults="$defaults;$repo_root/sdkconfig.emulator.defaults"
fi
if [ "$mode" = graphics ]; then
    printf 'CONFIG_PARTITION_TABLE_CUSTOM=y\nCONFIG_PARTITION_TABLE_CUSTOM_FILENAME="%s"\n' \
        "$repo_root/ports/esp32p4-native/partitions-graphics.csv" > "$build_dir/graphics.defaults"
    defaults="$defaults;$build_dir/graphics.defaults"
fi
idf.py -C "$repo_root/ports/esp32p4-native" -B "$boot_dir" \
    -D IDF_TARGET=esp32p4 -D "SDKCONFIG=$boot_dir/sdkconfig" \
    -D "SDKCONFIG_DEFAULTS=$defaults" bootloader partition-table
sh "$repo_root/tools/build-native-elf.sh" "$profile" "$build_dir" "$mode"
mkdir -p "$build_dir/licenses"
cp "$repo_root/src/board/tab5/bmi270/LICENSE" "$build_dir/licenses/BMI270.txt"
set -- --use_segments
# PMP code sits in the boot page after alignment padding. esptool must follow
# the load segment, or that padding becomes a second segment in the same 64 KiB
# mapping. Card, device, and network images already needed the same treatment.
"$python" -m esptool --chip esp32p4 elf2image \
    "$@" \
    --flash_mode dio --flash_freq 80m --flash_size 16MB \
    --min-rev-full "$revision" --max-rev-full "$max_revision" --elf-sha256-offset 0xb0 \
    -o "$build_dir/nihos-native.bin" \
    "$build_dir/nihos-native.elf"
"$python" -m esptool --chip esp32p4 merge_bin -o "$build_dir/nihos-native-flash.bin" \
    --flash_mode dio --flash_freq 80m --flash_size 16MB \
    0x2000 "$boot_dir/bootloader/bootloader.bin" \
    0x8000 "$boot_dir/partition_table/partition-table.bin" \
    0x10000 "$build_dir/nihos-native.bin"
set --
if [ "$mode" = sqlite ]; then set -- "$build_dir/sqlite-manifest.json"; fi
if [ "${NIHOS_NATIVE_DISPLAY:-0}" = 10 ] || [ "${NIHOS_NATIVE_DISPLAY:-0}" = 11 ]; then set -- --none "$build_dir/photo-manifest.json"; fi
if [ "${NIHOS_NATIVE_DISPLAY:-0}" = 9 ]; then set -- --none "$repo_root/src/graphics/card_read_font.json"; fi
if [ "${NIHOS_NATIVE_DISPLAY:-0}" = 8 ]; then set -- --none "$repo_root/src/graphics/keypad_atlas.json"; fi
if [ "$mode" = graphics ]; then set -- "$build_dir/graphics-manifest.json"; fi
if [ "${NIHOS_NATIVE_NORMAL_STORAGE:-0}" = 1 ]; then set -- "$@" --normal-fs "$build_dir/normal-fs-manifest.json"; fi
"$python" "$repo_root/tools/check-native-image.py" "$build_dir/nihos-native.elf" \
    "$build_dir/nihos-native.bin" "$build_dir/image-audit.json" "$mode" "$profile" \
    "$boot_dir/bootloader/bootloader.elf" "$boot_dir/config/sdkconfig.h" "$@"
if [ "${NIHOS_NATIVE_NETWORK:-0}" = 1 ]; then
    "$python" "$repo_root/tools/native-network-receipt.py" "$build_dir" "$native_sdk"
fi
