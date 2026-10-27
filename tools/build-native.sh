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
build_dir="$repo_root/build/native-$profile"
boot_dir="$build_dir/loader"
mode=${2:-integer}
case "$mode" in
    integer) ;;
    floating|compiled|sqlite) build_dir="$build_dir-$mode" ;;
    *) echo "mode must be integer, floating, compiled or sqlite" >&2; exit 1 ;;
esac
idf_path=${NIHOS_IDF_PATH:-${IDF_PATH:-"$HOME/esp32/esp-idf-v5.4.4"}}
if [ ! -f "$idf_path/export.sh" ]; then
    echo "ESP-IDF v5.4.4 not found; set NIHOS_IDF_PATH" >&2
    exit 1
fi
if ! command -v idf.py >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "$idf_path/export.sh" >/dev/null
fi
python=${NIHOS_IDF_PYTHON:-python}
mkdir -p "$build_dir"
# A failed rebuild must not expose an older image/audit as current output.
rm -f "$build_dir/image-audit.json" "$build_dir/nihos-native.bin" "$build_dir/nihos-native-flash.bin"
defaults="$repo_root/ports/esp32p4-native/sdkconfig.defaults"
if [ "$profile" = emulator ]; then
    defaults="$defaults;$repo_root/sdkconfig.emulator.defaults"
fi
idf.py -C "$repo_root/ports/esp32p4-native" -B "$boot_dir" \
    -D IDF_TARGET=esp32p4 -D "SDKCONFIG=$boot_dir/sdkconfig" \
    -D "SDKCONFIG_DEFAULTS=$defaults" bootloader partition-table
sh "$repo_root/tools/build-native-elf.sh" "$profile" "$build_dir" "$mode"
"$python" -m esptool --chip esp32p4 elf2image \
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
"$python" "$repo_root/tools/check-native-image.py" "$build_dir/nihos-native.elf" \
    "$build_dir/nihos-native.bin" "$build_dir/image-audit.json" "$mode" "$profile" \
    "$boot_dir/bootloader/bootloader.elf" "$boot_dir/config/sdkconfig.h" "$@"
