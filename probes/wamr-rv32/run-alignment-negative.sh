#!/bin/sh
# Test-only deliberate RV32 alignment fault; no device or flash write.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
out="$root/build/wasm-alignment-negative"
cc=${NIHOS_RISCV_CC:-riscv32-esp-elf-gcc}
python=${NIHOS_IDF_PYTHON:-python3}
loader="$root/build/native-emulator/loader"
mkdir -p "$out"
NIHOS_NATIVE_WASM_ALIGN_NEGATIVE=1 NIHOS_NATIVE_WASM_ALIGN_SAN=1 NIHOS_NATIVE_WASM_SESSION_TEST=1 NIHOS_NATIVE_WASM_TASK=1 NIHOS_NATIVE_BOOT_TEST=1 \
    sh "$root/tools/build-native-elf.sh" emulator "$out" wasm > "$out/build.log" 2>&1 || { cat "$out/build.log"; exit 1; }
"${cc%gcc}objdump" -dr "$out/wamr_c_align_negative.o" > "$out/negative-assembly.txt"
"${cc%gcc}nm" "$out/nihos-native.elf" > "$out/symbols.txt"
grep -q '__ubsan_handle_type_mismatch_v1_abort' "$out/negative-assembly.txt"
grep -q ' __ubsan_handle_type_mismatch_v1_abort$' "$out/symbols.txt"
"${cc%gcc}objcopy" --strip-debug "$out/nihos-native.elf" "$out/nihos-native-image.elf"
"$python" -m esptool --chip esp32p4 elf2image --use_segments --flash_mode dio --flash_freq 80m --flash_size 16MB \
    --min-rev-full 300 --max-rev-full 399 --elf-sha256-offset 0xb0 -o "$out/nihos-native.bin" "$out/nihos-native-image.elf" > "$out/image.log" 2>&1
"$python" -m esptool --chip esp32p4 merge_bin -o "$out/nihos-native-flash.bin" --flash_mode dio --flash_freq 80m --flash_size 16MB \
    0x2000 "$loader/bootloader/bootloader.bin" 0x8000 "$loader/partition_table/partition-table.bin" 0x10000 "$out/nihos-native.bin" >> "$out/image.log" 2>&1
emu=$(sh "$root/tools/bootstrap-esp-emu.sh")
python3 - "$emu" "$out" <<'PY'
import hashlib,json,re,subprocess,sys
from pathlib import Path
emu,out=sys.argv[1],Path(sys.argv[2]); names=('nihos-native-image.elf','nihos-native-flash.bin')
hashes={name:hashlib.sha256((out/name).read_bytes()).hexdigest() for name in names}
cmd=[emu,'--chip','esp32p4','--firmware',str(out/names[1]),'--elf',str(out/names[0]),'--psram-size','4M','--timeout','60s','--exit-on','align_log2=00000002']
r=subprocess.run(cmd,capture_output=True,text=True,timeout=65)
(out/'negative.log').write_text(r.stdout); (out/'negative-stderr.log').write_text(r.stderr)
assert r.returncode==0 and 'NIHOS_WAMR_ALIGN_NEGATIVE_BEGIN' in r.stdout and 'NIHOS_NATIVE_FAIL' not in r.stdout,(r.returncode,r.stdout)
m=re.search(r'NIHOS_WAMR_ALIGN_TRAP file=(\S*ubsan_alignment_negative\.c) line=([0-9a-f]{8}) address=([0-9a-f]{8}) align_log2=00000002',r.stdout)
assert m and int(m[2],16)>0 and int(m[3],16)%4==1,r.stdout
assert all(hashlib.sha256((out/f).read_bytes()).hexdigest()==h for f,h in hashes.items())
(out/'report.json').write_text(json.dumps({'scope':'RV32 emulator GCC alignment sanitizer negative control','candidate':hashes,'source':m[1],'line':int(m[2],16),'address_mod4':int(m[3],16)%4},indent=2)+'\n')
print('RV32 alignment sanitizer negative control: expected trap observed')
PY
