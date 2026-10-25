#!/bin/sh
# Build an independent SRAM application; ESP-IDF supplies only boot artifacts.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
profile=${1:-device}
case "$profile" in
    device) revision=100; max_revision=299; rev3=0 ;;
    emulator) revision=300; max_revision=399; rev3=1 ;;
    *) echo "usage: $0 [device|emulator]" >&2; exit 1 ;;
esac
build_dir="$repo_root/build/native-$profile"
boot_dir="$build_dir/loader"
zig="$repo_root/.tools/zig-0.17.0/zig"
if [ ! -x "$zig" ]; then sh "$repo_root/tools/bootstrap-zig.sh" >/dev/null; fi
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
defaults="$repo_root/ports/esp32p4-native/sdkconfig.defaults"
if [ "$profile" = emulator ]; then
    defaults="$defaults;$repo_root/sdkconfig.emulator.defaults"
fi
idf.py -C "$repo_root/ports/esp32p4-native" -B "$boot_dir" \
    -D IDF_TARGET=esp32p4 -D "SDKCONFIG=$boot_dir/sdkconfig" \
    -D "SDKCONFIG_DEFAULTS=$defaults" bootloader partition-table
"$zig" build-exe -target riscv32-freestanding-none \
    -mcpu=generic_rv32+m+a+c+zicsr+zifencei -O safe -fllvm -fno-strip \
    -fno-stack-check -fno-stack-protector -fno-unwind-tables \
    -fentry=nih_native_start -T "$repo_root/src/platform/native/esp32p4.ld" \
    -DNIH_NATIVE_REV3="$rev3" \
    "$repo_root/src/platform/native/start.S" \
    --dep timer_group -Mroot="$repo_root/src/platform/native/main.zig" \
    -target riscv32-freestanding-none -mcpu=generic_rv32+m+a+c+zicsr+zifencei -O safe \
    -Mtimer_group="$repo_root/src/soc/esp32p4/timer_group.zig" \
    -femit-bin="$build_dir/nihos-native.elf"
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
"$python" "$repo_root/tools/check-native-image.py" "$build_dir/nihos-native.elf" \
    "$build_dir/nihos-native.bin" "$build_dir/image-audit.json"
