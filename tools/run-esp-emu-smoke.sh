#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
build_dir=${NIHOS_EMULATOR_BUILD_DIR:-"$repo_root/build/espidf-emulator"}
marker="nihos: core smoke complete"

sh "$repo_root/tools/build-espidf-emulator.sh"
emulator=$(sh "$repo_root/tools/bootstrap-esp-emu.sh")

if ! output=$("$emulator" \
    --chip esp32p4 \
    --firmware "$build_dir/nihos-flash.bin" \
    --elf "$build_dir/nihos.elf" \
    --psram-size 32M \
    --timeout 30s \
    --exit-on "$marker" 2>&1); then
    printf '%s\n' "$output" >&2
    exit 1
fi
printf '%s\n' "$output"
if ! printf '%s\n' "$output" | grep -Fq "$marker"; then
    echo "ESP-EMU exited without the core smoke marker" >&2
    exit 1
fi
