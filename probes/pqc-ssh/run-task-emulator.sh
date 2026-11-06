#!/bin/sh
# Headless emulator fixture only; never flashes a device.
set -eu
: "${NIHOS_MLKEM_ARCHIVE:?set NIHOS_MLKEM_ARCHIVE to the pinned ML-KEM source tarball}"
: "${NIHOS_EMU:?set NIHOS_EMU to ESP-EMU 0.50.0}"
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"
NIHOS_NATIVE_BOOT_TEST=1 NIHOS_NATIVE_PQC_TASK=1 NIHOS_NATIVE_PQC_SSH_NEGATIVE=0 sh tools/build-native.sh emulator
out="$root/build/native-emulator"
for size in 4M 0; do
    "$NIHOS_EMU" --chip esp32p4 --firmware "$out/nihos-native-flash.bin" --elf "$out/nihos-native.elf" \
        --psram-size "$size" --timeout 45s --exit-on NIHOS_PQC_TASK_DONE > "$out/pqc-task-$size.log" 2>&1
    python3 probes/pqc-ssh/check_task_log.py "$out/pqc-task-$size.log" "$out/nihos-native.elf" "$out/nihos-native.bin" "$out/image-audit.json" "$size"
done
