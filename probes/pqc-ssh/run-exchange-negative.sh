#!/bin/sh
# Four separate test-only images; never flash hardware.
set -eu
: "${NIHOS_MLKEM_ARCHIVE:?set pinned ML-KEM source tarball}"
: "${NIHOS_EMU:?set ESP-EMU 0.50.0}"
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"
out="$root/build/native-emulator"
for mode in 1 2 3 4; do
    case "$mode" in 1) label=bad-ct ;; 2) label=bad-pin ;; 3) label=timeout ;; 4) label=bad-signature ;; esac
    NIHOS_NATIVE_BOOT_TEST=1 NIHOS_NATIVE_PQC_TASK=1 NIHOS_NATIVE_PQC_SSH_NEGATIVE="$mode" sh tools/build-native.sh emulator
    "$NIHOS_EMU" --chip esp32p4 --firmware "$out/nihos-native-flash.bin" --elf "$out/nihos-native.elf" \
        --psram-size 4M --timeout 45s --exit-on NIHOS_PQC_TASK_DONE > "$out/pqc-task-$label.log" 2>&1
    python3 probes/pqc-ssh/check_task_log.py "$out/pqc-task-$label.log" "$out/nihos-native.elf" "$out/nihos-native.bin" "$out/image-audit.json" "$label"
    saved="$root/build/pqc-ssh-exchange-$label"
    mkdir -p "$saved"
    cp "$out/nihos-native.elf" "$out/nihos-native.bin" "$out/image-audit.json" "$out/pqc-task-$label.log" "$saved/"
done
