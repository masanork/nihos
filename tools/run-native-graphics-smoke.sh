#!/bin/sh
# Native P4 emulator only. Does not open serial ports or write hardware Flash.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
build_dir="$repo_root/build/native-emulator-graphics"
result_dir="$build_dir/case-32M"
mkdir -p "$result_dir"
rm -f "$result_dir/graphics-smoke.json"
sh tools/build-native.sh emulator graphics
cp "$build_dir/nihos-native.elf" "$build_dir/nihos-native.bin" "$build_dir/nihos-native-flash.bin" \
    "$build_dir/image-audit.json" "$build_dir/graphics-manifest.json" "$result_dir/"
cp "$build_dir/loader/config/sdkconfig.h" "$build_dir/loader/bootloader/bootloader.elf" \
    "$build_dir/loader/partition_table/partition-table.bin" "$result_dir/"
emulator=$(sh tools/bootstrap-esp-emu.sh)
"$emulator" --chip esp32p4 --firmware "$result_dir/nihos-native-flash.bin" \
    --elf "$result_dir/nihos-native.elf" --psram-size 32M --timeout 180s \
    --exit-on NIHOS_NATIVE_GRAPHICS_PASS > "$result_dir/emulator.log" 2>&1
python3 tools/check-native-graphics.py "$result_dir"
