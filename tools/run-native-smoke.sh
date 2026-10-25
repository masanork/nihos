#!/bin/sh
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
build_dir="$repo_root/build/native-emulator"
mode=${1:-integer}
case "$mode" in
    integer) ;;
    floating) build_dir="$build_dir-floating" ;;
    *) echo "usage: $0 [integer|floating]" >&2; exit 1 ;;
esac
# A failed rerun must not leave an earlier success report looking current.
rm -f "$build_dir/smoke-report.json"
sh "$repo_root/tools/build-native.sh" emulator "$mode"
emulator=$(sh "$repo_root/tools/bootstrap-esp-emu.sh")
marker=NIHOS_NATIVE_FP_PASS
if ! "$emulator" --chip esp32p4 --firmware "$build_dir/nihos-native-flash.bin" \
    --elf "$build_dir/nihos-native.elf" --psram-size 0 --timeout 60s \
    --exit-on "$marker" > "$build_dir/emulator.log" 2>&1; then
    cat "$build_dir/emulator.log" >&2
    exit 1
fi
cat "$build_dir/emulator.log"
python3 "$repo_root/tools/check-native-log.py" "$build_dir/emulator.log" \
    "$build_dir/smoke-report.json" "$mode"
