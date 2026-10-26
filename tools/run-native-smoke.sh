#!/bin/sh
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
build_dir="$repo_root/build/native-emulator"
mode=${1:-integer}
psram_size=${2:-0}
case "$mode" in
    integer) ;;
    floating|compiled) build_dir="$build_dir-$mode" ;;
    *) echo "usage: $0 [integer|floating|compiled] [0|4M|8M|16M|32M|64M]" >&2; exit 1 ;;
esac
case "$psram_size" in
    0|4M|8M|16M|32M|64M) ;;
    *) echo "unsupported PSRAM size: $psram_size" >&2; exit 1 ;;
esac
result_dir="$build_dir/psram-$psram_size"
mkdir -p "$result_dir"
# A failed rerun must not leave an earlier success report looking current.
rm -f "$result_dir/smoke-report.json"
# Retire the earlier unbound default-case locations.
if [ "$psram_size" = 0 ]; then rm -f "$build_dir/smoke-report.json" "$build_dir/emulator.log"; fi
sh "$repo_root/tools/build-native.sh" emulator "$mode"
# A later case rebuild may change debug metadata/cache paths in the ELF.
# Execute and validate this case's retained image, never a mutable mode alias.
cp "$build_dir/nihos-native.elf" "$build_dir/nihos-native.bin" \
    "$build_dir/nihos-native-flash.bin" "$build_dir/image-audit.json" \
    "$build_dir/native-layout.ld" "$result_dir/"
emulator=$(sh "$repo_root/tools/bootstrap-esp-emu.sh")
marker=NIHOS_NATIVE_FP_PASS
if ! "$emulator" --chip esp32p4 --firmware "$result_dir/nihos-native-flash.bin" \
    --elf "$result_dir/nihos-native.elf" --psram-size "$psram_size" --timeout 60s \
    --exit-on "$marker" > "$result_dir/emulator.log" 2>&1; then
    cat "$result_dir/emulator.log" >&2
    exit 1
fi
cat "$result_dir/emulator.log"
python3 "$repo_root/tools/check-native-log.py" "$result_dir/emulator.log" \
    "$result_dir/smoke-report.json" "$mode" "$psram_size" "$result_dir/image-audit.json"
