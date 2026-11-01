#!/bin/sh
# Emulator UART -> normal UI poll/decoder/dispatcher -> WAMR. No LCD scanout.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
out="$root/build/wasm-interactive"
riscv_cc=${NIHOS_RISCV_CC:-riscv32-esp-elf-gcc}
python=${NIHOS_IDF_PYTHON:-python3}
loader="$root/build/native-emulator/loader"
mkdir -p "$out"
NIHOS_NATIVE_WASM_INTERACTIVE=1 NIHOS_NATIVE_WASM_SESSION_TEST=1 NIHOS_NATIVE_WASM_TASK=1 NIHOS_NATIVE_BOOT_TEST=1 \
    sh "$root/tools/build-native-elf.sh" emulator "$out" wasm > "$out/build.log" 2>&1 || { cat "$out/build.log"; exit 1; }
"${riscv_cc%gcc}objcopy" --strip-debug "$out/nihos-native.elf" "$out/nihos-native-image.elf"
"$python" -m esptool --chip esp32p4 elf2image --use_segments --flash_mode dio --flash_freq 80m --flash_size 16MB \
    --min-rev-full 300 --max-rev-full 399 --elf-sha256-offset 0xb0 -o "$out/nihos-native.bin" "$out/nihos-native-image.elf" > "$out/image.log" 2>&1
"$python" -m esptool --chip esp32p4 merge_bin -o "$out/nihos-native-flash.bin" --flash_mode dio --flash_freq 80m --flash_size 16MB \
    0x2000 "$loader/bootloader/bootloader.bin" 0x8000 "$loader/partition_table/partition-table.bin" 0x10000 "$out/nihos-native.bin" >> "$out/image.log" 2>&1
python3 "$root/probes/wamr-native/check-image.py" "$out/nihos-native-image.elf" "$out/app.wasm" "$out/app-test-ed25519.nihpkg" "$out/app-update-ed25519.nihpkg" "$out/image-audit.json" --session
emulator=$(sh "$root/tools/bootstrap-esp-emu.sh")
python3 - "$emulator" "$out" <<'PY'
import hashlib,json,subprocess,sys
from pathlib import Path
emu,out=sys.argv[1],Path(sys.argv[2]); names=('nihos-native-image.elf','nihos-native-flash.bin')
hashes={name:hashlib.sha256((out/name).read_bytes()).hexdigest() for name in names}
records=[]
for case,trigger,payload,done in [('active','NIHOS_WASM_INTERACTIVE_ACTIVE','010q','NIHOS_WASM_INTERACTIVE_PASS'),('cancel','NIHOS_WASM_INTERACTIVE_OPENING','q','NIHOS_WASM_INTERACTIVE_CANCEL_PASS')]:
    cmd=[emu,'--chip','esp32p4','--firmware',str(out/names[1]),'--elf',str(out/names[0]),'--psram-size','4M','--timeout','60s','--exit-on',done,
         '--inject','\x1b','--inject-on','NIHOS_WASM_INTERACTIVE_READY','--inject','rust-app\r','--inject-on','NIHOS_NATIVE_SESSION_VIEW',
         '--inject',payload,'--inject-on',trigger]
    r=subprocess.run(cmd,capture_output=True,text=True,timeout=70)
    (out/f'{case}.log').write_text(r.stdout); (out/f'{case}-stderr.log').write_text(r.stderr)
    assert r.returncode==0 and 'NIHOS_NATIVE_FAIL' not in r.stdout,(case,r.returncode,r.stdout)
    for marker in ('NIHOS_WASM_INTERACTIVE_READY','NIHOS_NATIVE_SESSION_VIEW','NIHOS_WASM_INTERACTIVE_OPENING',done):
        assert sum(line.startswith(marker) for line in r.stdout.splitlines())==1,(case,marker,r.stdout)
    assert ('NIHOS_WASM_INTERACTIVE_ACTIVE' in r.stdout)==(case=='active'),(case,r.stdout)
    assert all(hashlib.sha256((out/f).read_bytes()).hexdigest()==h for f,h in hashes.items())
    records.append({'case':case,'result':'pass'}); print(f'{case}: UI UART polling, pixel/recovery assertions passed',flush=True)
(out/'report.json').write_text(json.dumps({'scope':'RV32 emulator UART and actual UI polling with substitute shell and pixel presenter; no USB JTAG or physical scanout','candidate':hashes,'cases':records},indent=2)+'\n')
PY
