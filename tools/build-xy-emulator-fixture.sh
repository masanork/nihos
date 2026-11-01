#!/bin/sh
# Reproducible guest for the experimental desktop emulator; never flashes hardware.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
export NIHOS_NATIVE_DISPLAY=2 NIHOS_NATIVE_PSRAM_200=1 NIHOS_NATIVE_CONSOLE=1
export NIHOS_NATIVE_CONSOLE_LIVE=1 NIHOS_NATIVE_XY_WORKSPACE=1 NIHOS_NATIVE_CPU_MHZ=0
export NIHOS_NATIVE_KEYBOARD_I2C=1 NIHOS_NATIVE_NETWORK=0 NIHOS_NATIVE_DEVICES=1
export NIHOS_NATIVE_NORMAL_STORAGE=0 NIHOS_NATIVE_SQLD=0 NIHOS_NATIVE_CAMERA_ID=0
export NIHOS_NATIVE_CONSOLE_FONT=3
sh tools/build-native.sh device integer
mkdir -p build/xy-emulator-firmware
cp build/native-device-devices/nihos-native.elf build/xy-emulator-firmware/nihos-native.elf.tmp
mv build/xy-emulator-firmware/nihos-native.elf.tmp build/xy-emulator-firmware/nihos-native.elf
printf '%s\n' "$repo_root/build/xy-emulator-firmware/nihos-native.elf"
