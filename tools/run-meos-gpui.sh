#!/bin/sh
# Run the pinned, volatile MeOS fixture in a development GPUI build.
set -eu

usage() {
    cat <<'HELP'
Usage: tools/run-meos-gpui.sh [MEOS_BUILD_DIR [ROM_ELF]]

Launch the experimental MeOS window using the identified shi3z build.
The default image is build/external-firmware/meos-shi3z-latest/m5os.bin
or ../MeOS-shi3z-latest/build-tab5/m5os.bin. The default ROM is from the
ESP-IDF 20241011 ROM ELF package. Image and ROM hashes are checked by the app.
Guest flash is volatile and is cleared on reset. Tab5 hardware is not fully modeled.
HELP
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then usage; exit 0; fi
if [ "$#" -gt 2 ]; then usage >&2; exit 2; fi
repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -ge 1 ]; then
    build_dir=$1
elif [ -f "$repo_dir/build/external-firmware/meos-shi3z-latest/m5os.bin" ]; then
    build_dir=$repo_dir/build/external-firmware/meos-shi3z-latest
else
    build_dir=$repo_dir/../MeOS-shi3z-latest/build-tab5
fi
rom_path=${2:-"${HOME:?HOME is required for the default ROM path}/.espressif/tools/esp-rom-elfs/20241011/esp32p4_rev0_rom.elf"}
[ -f "$build_dir/m5os.bin" ] || { printf 'MeOS image not found: %s\nPass MEOS_BUILD_DIR as the first argument.\n' "$build_dir/m5os.bin" >&2; exit 1; }
[ -f "$rom_path" ] || { printf 'ROM ELF not found: %s\nPass ROM_ELF as the second argument.\n' "$rom_path" >&2; exit 1; }
export NIHOS_EXPERIMENTAL_MEOS_APP="$build_dir/m5os.bin"
export NIHOS_EXPERIMENTAL_MEOS_ROM="$rom_path"
exec cargo run --locked --manifest-path "$repo_dir/apps/xy-gpui/Cargo.toml" --features experimental-meos
