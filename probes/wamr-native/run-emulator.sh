#!/bin/sh
# Executable ESP32-P4 emulator fixture. This is not physical-device evidence.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
out="$root/build/native-emulator-wasm"
loader="$root/build/native-emulator/loader"
zig=${NIHOS_ZIG:-"$root/.tools/zig-0.17.0/zig"}
riscv_cc=${NIHOS_RISCV_CC:-riscv32-esp-elf-gcc}
idf_python=${NIHOS_IDF_PYTHON:-}
[ -x "$zig" ] || { echo "Set NIHOS_ZIG to Zig 0.17.0" >&2; exit 1; }
if [ -z "$idf_python" ]; then
    for candidate in python python3; do
        if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -m esptool version >/dev/null 2>&1; then
            idf_python=$(command -v "$candidate")
            break
        fi
    done
fi
[ -n "$idf_python" ] && [ -x "$idf_python" ] || { echo "Set NIHOS_IDF_PYTHON to an esptool environment" >&2; exit 1; }
command -v "$riscv_cc" >/dev/null 2>&1 || { echo "Set NIHOS_RISCV_CC" >&2; exit 1; }
[ -f "$loader/bootloader/bootloader.bin" ] && [ -f "$loader/partition_table/partition-table.bin" ] || {
    echo "Build the emulator bootloader once with: sh tools/build-native.sh emulator integer" >&2
    exit 1
}
mkdir -p "$out"
# Do not let an object from the superseded independently linked Wasm path make
# the retained build directory look like the current candidate still uses it.
rm -f "$out/wamr_blob.o"
(cd "$root" && "$zig" build test-app --summary all) > "$out/host-tests.log" 2>&1
NIHOS_ZIG="$zig" sh "$root/probes/wamr-native/run-package-process.sh" \
    > "$out/package-process-test.log" 2>&1
NIHOS_ZIG="$zig" NIHOS_RISCV_CC="$riscv_cc" \
    sh "$root/probes/wamr-native/run-boot-admission-rv32.sh" > "$out/boot-admission-rv32.log" 2>&1
NIHOS_ZIG="$zig" NIHOS_RISCV_CC="$riscv_cc" \
    sh "$root/tools/build-native-elf.sh" emulator "$out" wasm > "$out/build.log"
"$zig" test --dep app_package \
    -Mroot="$root/src/app/package_ed25519.zig" \
    --dep app_policy -Mapp_package="$root/src/app/package.zig" \
    -Mapp_policy="$root/src/app/module_policy.zig" > "$out/ed25519-rfc-test.log" 2>&1
cp "$root/probes/wamr-native/wasm-blob.zig" "$out/wasm-blob.zig"
"$zig" test --dep app_package --dep package_ed25519 --dep app_install --dep app_policy --dep wasm_blob \
    -Mroot="$root/probes/wamr-native/package-ed25519-test.zig" \
    --dep app_policy -Mapp_package="$root/src/app/package.zig" \
    --dep app_package -Mpackage_ed25519="$root/src/app/package_ed25519.zig" \
    --dep app_package --dep app_policy -Mapp_install="$root/src/app/package_install.zig" \
    -Mapp_policy="$root/src/app/module_policy.zig" \
    -Mwasm_blob="$out/wasm-blob.zig" > "$out/package-ed25519-test.log" 2>&1
prefix=${riscv_cc%gcc}
image_elf="$out/nihos-native-image.elf"
"${prefix}objcopy" --strip-debug "$out/nihos-native.elf" "$image_elf"
"$idf_python" -m esptool --chip esp32p4 elf2image --use_segments \
    --flash_mode dio --flash_freq 80m --flash_size 16MB \
    --min-rev-full 300 --max-rev-full 399 --elf-sha256-offset 0xb0 \
    -o "$out/nihos-native.bin" "$image_elf" >/dev/null
"$idf_python" -m esptool --chip esp32p4 merge_bin \
    -o "$out/nihos-native-flash.bin" --flash_mode dio --flash_freq 80m \
    --flash_size 16MB 0x2000 "$loader/bootloader/bootloader.bin" \
    0x8000 "$loader/partition_table/partition-table.bin" \
    0x10000 "$out/nihos-native.bin" >/dev/null
emulator=$(sh "$root/tools/bootstrap-esp-emu.sh")
"$emulator" --chip esp32p4 --firmware "$out/nihos-native-flash.bin" \
    --elf "$image_elf" --psram-size 4M --timeout 60s \
    --inject '0x10q' --inject-on NIHOS_WAMR_UART_READY \
    --exit-on NIHOS_NATIVE_FP_PASS > "$out/emulator.log" 2>&1
python3 - "$out/emulator.log" "$out/app.wasm" <<'PY'
import hashlib, re, sys
from pathlib import Path
text=Path(sys.argv[1]).read_text(errors='replace')
if 'NIHOS_NATIVE_FAIL' in text:
    raise SystemExit('native failure marker present')
matches=re.findall(r'^NIHOS_NATIVE_WAMR (.+)$',text,re.M)
if len(matches)!=1:
    raise SystemExit(f'expected one WAMR record, found {len(matches)}')
fields=dict(part.split('=',1) for part in matches[0].split())
digest_tag=int.from_bytes(hashlib.sha256(Path(sys.argv[2]).read_bytes()).digest()[:4], 'little')
expected={'status':'00000000','calls':'00000011','trapped':'00000001',
          'metered':'00000001','bad_text':'00000001','cycles':'00000002',
          'cycle_recovered':'00000001','recovered':'00000001',
          'linear_peak':'00010000','export_count':'00000008','lease_bytes':'0007a000',
          'policy_status':'00000000','services':'00000001','sdk_abi':'00000001',
          'origin':'00000001','attestation':'00000002','module_tag':'6f68696e',
          'digest_tag':f'{digest_tag:08x}','instruction_budget':'00002710'}
bad={key:(fields.get(key),value) for key,value in expected.items() if fields.get(key)!=value}
if bad:
    raise SystemExit(f'WAMR evidence mismatch: {bad}')
owner_matches=re.findall(r'^NIHOS_NATIVE_WAMR_OWNER (.+)$',text,re.M)
if len(owner_matches)!=1:
    raise SystemExit('expected one native owner record')
owner_fields=dict(part.split('=',1) for part in owner_matches[0].split())
if owner_fields != {'checks':'0000000f','released':'00000001','services':'00000001'}:
    raise SystemExit(f'native owner evidence mismatch: {owner_fields}')
surface_matches=re.findall(r'^NIHOS_NATIVE_WAMR_SURFACE (.+)$',text,re.M)
if surface_matches != ['checks=0000007f width=000000a0 height=00000050 stride=00000144 bytes=00006540 capacity=00008000']:
    raise SystemExit(f'native surface evidence mismatch: {surface_matches}')
event_matches=re.findall(r'^NIHOS_NATIVE_WAMR_EVENTS (.+)$',text,re.M)
if event_matches != ['checks=0000001f frames=00000003']:
    raise SystemExit(f'native event evidence mismatch: {event_matches}')
uart_matches=re.findall(r'^NIHOS_NATIVE_WAMR_UART (.+)$',text,re.M)
if uart_matches != ['status=00000001 bytes=00000005 frames=00000003 rejected=00000001']:
    raise SystemExit(f'native UART evidence mismatch: {uart_matches}')
if len(re.findall(r'^NIHOS_WAMR_UART_READY\r?$',text,re.M)) != 1:
    raise SystemExit('UART readiness marker differs')
package_matches=re.findall(r'^NIHOS_NATIVE_PACKAGE (.+)$',text,re.M)
if len(package_matches)!=1:
    raise SystemExit(f'expected one package record, found {len(package_matches)}')
package_fields=dict(part.split('=',1) for part in package_matches[0].split())
package_expected={'signature_status':'00000001','package_trust':'00000000',
                  'initial_sequence_low':'00000001','initial_sequence_high':'00000000',
                  'interrupted_update_recovered':'00000001',
                  'installed_sequence_low':'00000002','installed_sequence_high':'00000000',
                  'package_sequence_low':'00000002','package_sequence_high':'00000000',
                  'package_syncs':'00000003','simulated_reboot':'00000001',
                  'package_rejected':'00000001','boot_recovered':'00000001',
                  'trust_epoch_low':'00000001','trust_epoch_high':'00000000'}
package_bad={key:(package_fields.get(key),value) for key,value in package_expected.items()
             if package_fields.get(key)!=value}
if package_bad:
    raise SystemExit(f'package admission failed: {package_bad}')
cycles=int(package_fields.get('boot_admission_cycles','0'),16)
if cycles <= 0 or cycles > 0x40000000:
    raise SystemExit(f'invalid boot_admission_cycles: {package_fields.get("boot_admission_cycles")}')
stack=int(package_fields.get('boot_admission_stack_used','0'),16)
if stack <= 0 or stack > 0x10000:
    raise SystemExit(f'invalid boot_admission_stack_used: {package_fields.get("boot_admission_stack_used")}')
if text.count('NIHOS_NATIVE_SMP_PASS rounds=100 timers=both rtos=none') != 3:
    raise SystemExit('post-WAMR SMP qualification incomplete')
if text.count('NIHOS_NATIVE_SOAK_PASS rounds=300 timers=both rtos=none') != 1:
    raise SystemExit('post-WAMR soak qualification incomplete')
if text.count('NIHOS_NATIVE_FP_PASS floating=0') != 1:
    raise SystemExit('native completion marker missing')
print('WAMR Rust app native emulator fixture: ok')
PY
python3 "$root/probes/wamr-native/run-uart-matrix.py" "$emulator" "$out"
[ -z "$("${prefix}nm" -u "$image_elf")" ] || {
    echo "WAMR native ELF has undefined symbols" >&2
    exit 1
}
python3 "$root/probes/wamr-native/check-image.py" "$image_elf" \
    "$out/app.wasm" "$out/app-test-ed25519.nihpkg" \
    "$out/app-update-ed25519.nihpkg" "$out/image-audit-wamr.json"
shasum -a 256 "$out/boot_trust.bin" "$out/boot_package.bin" \
    "$out/boot_counter.bin" "$out/boot_root.pub" \
    "$out/app-update-ed25519.nihpkg" > "$out/boot-media-sha256.txt"
shasum -a 256 "$out/app.wasm" "$out/app-test-ed25519.nihpkg" \
    "$out/app-update-ed25519.nihpkg" \
    "$image_elf" "$out/nihos-native-flash.bin" |
    tee "$out/candidate-sha256.txt"
