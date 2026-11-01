#!/bin/sh
# Test-only uncompressed Rust call_indirect compatibility negative control.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
out="$root/build/wasm-alignment-corpus-uncompressed"
cc=${NIHOS_RISCV_CC:-riscv32-esp-elf-gcc}
python=${NIHOS_IDF_PYTHON:-python3}
loader="$root/build/native-emulator/loader"
mkdir -p "$out"
NIHOS_NATIVE_WASM_ALIGN_CORPUS=1 NIHOS_NATIVE_WASM_ALIGN_CORPUS_UNCOMPRESSED=1 NIHOS_NATIVE_WASM_SESSION_TEST=1 NIHOS_NATIVE_WASM_TASK=1 NIHOS_NATIVE_BOOT_TEST=1 \
    sh "$root/tools/build-native-elf.sh" emulator "$out" wasm > "$out/build.log" 2>&1 || { cat "$out/build.log"; exit 1; }
node "$root/probes/rust-wasm/test-alignment.mjs" "$out/app.wasm" > "$out/node.log"
"${cc%gcc}objcopy" --strip-debug "$out/nihos-native.elf" "$out/nihos-native-image.elf"
"$python" -m esptool --chip esp32p4 elf2image --use_segments --flash_mode dio --flash_freq 80m --flash_size 16MB \
    --min-rev-full 300 --max-rev-full 399 --elf-sha256-offset 0xb0 -o "$out/nihos-native.bin" "$out/nihos-native-image.elf" > "$out/image.log" 2>&1
"$python" -m esptool --chip esp32p4 merge_bin -o "$out/nihos-native-flash.bin" --flash_mode dio --flash_freq 80m --flash_size 16MB \
    0x2000 "$loader/bootloader/bootloader.bin" 0x8000 "$loader/partition_table/partition-table.bin" 0x10000 "$out/nihos-native.bin" >> "$out/image.log" 2>&1
python3 "$root/probes/wamr-native/check-image.py" "$out/nihos-native-image.elf" "$out/app.wasm" "$out/app-test-ed25519.nihpkg" "$out/app-update-ed25519.nihpkg" "$out/image-audit.json" --session
emu=$(sh "$root/tools/bootstrap-esp-emu.sh")
python3 - "$emu" "$out" <<'PY'
import hashlib,json,subprocess,sys
from pathlib import Path
emu,out=sys.argv[1],Path(sys.argv[2]);names=('nihos-native-image.elf','nihos-native-flash.bin','app.wasm')
hashes={f:hashlib.sha256((out/f).read_bytes()).hexdigest() for f in names}
needle='zero byte expected. The module uses reference types feature which is disabled in the runtime.'
cmd=[emu,'--chip','esp32p4','--firmware',str(out/names[1]),'--elf',str(out/names[0]),'--psram-size','4M','--timeout','60s','--exit-on',needle]
r=subprocess.run(cmd,capture_output=True,text=True,timeout=65)
(out/'negative.log').write_text(r.stdout);(out/'negative-stderr.log').write_text(r.stderr)
assert r.returncode==0 and 'NIHOS_WAMR_CORPUS_FAIL stage=load detail=' in r.stdout and needle in r.stdout,r.stdout
assert 'NIHOS_WAMR_CORPUS_PASS' not in r.stdout and 'NIHOS_WAMR_ALIGN_TRAP' not in r.stdout,r.stdout
assert all(hashlib.sha256((out/f).read_bytes()).hexdigest()==h for f,h in hashes.items())
(out/'report.json').write_text(json.dumps({'scope':'uncompressed Rust corpus, headless emulator load negative; no device','candidate':hashes,'expected_error':needle},indent=2)+'\n')
print('Uncompressed call_indirect: Node accepted, selected WAMR loader rejected as expected')
PY
