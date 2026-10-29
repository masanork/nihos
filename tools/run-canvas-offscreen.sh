#!/bin/sh
# Execute the actual RV32 Canvas pattern, without touching a physical device.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
build="$root/build/native-emulator"
out="$build/canvas-offscreen"
mkdir -p "$out"
rm -f "$out/report.json"
NIHOS_NATIVE_CANVAS_OFFSCREEN=1 NIHOS_NATIVE_QUALIFICATION=1 NIHOS_NATIVE_DISPLAY=0 \
    sh tools/build-native.sh emulator integer
cp "$build/nihos-native.elf" "$build/nihos-native.bin" "$build/nihos-native-flash.bin" \
    "$build/image-audit.json" "$build/native_options.zig" "$out/"
emulator=$(sh tools/bootstrap-esp-emu.sh)
"$emulator" --chip esp32p4 --firmware "$out/nihos-native-flash.bin" \
    --elf "$out/nihos-native.elf" --psram-size 32M --timeout 180s \
    --exit-on NIHOS_NATIVE_CANVAS_OFFSCREEN_PASS > "$out/emulator.log" 2> "$out/emulator-stderr.log"
python3 tools/check-canvas-offscreen.py "$out"
printf 'Evidence: %s\n' "$out/report.json"
