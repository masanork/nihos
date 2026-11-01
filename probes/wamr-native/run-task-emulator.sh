#!/bin/sh
# WAMR runs in a registered native task, not through the boot SP-switch fixture.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
out="$root/build/wamr-task-emulator"
riscv_cc=${NIHOS_RISCV_CC:-riscv32-esp-elf-gcc}
python=${NIHOS_IDF_PYTHON:-python3}
loader="$root/build/native-emulator/loader"
mkdir -p "$out"
NIHOS_NATIVE_WASM_TASK=1 NIHOS_NATIVE_BOOT_TEST=1 \
    sh "$root/tools/build-native-elf.sh" emulator "$out" wasm > "$out/build.log" 2>&1 || {
    cat "$out/build.log"; exit 1;
}
"${riscv_cc%gcc}objcopy" --strip-debug "$out/nihos-native.elf" "$out/nihos-native-image.elf"
"$python" -m esptool --chip esp32p4 elf2image --use_segments \
    --flash_mode dio --flash_freq 80m --flash_size 16MB \
    --min-rev-full 300 --max-rev-full 399 --elf-sha256-offset 0xb0 \
    -o "$out/nihos-native.bin" "$out/nihos-native-image.elf" > "$out/image.log" 2>&1
"$python" -m esptool --chip esp32p4 merge_bin \
    -o "$out/nihos-native-flash.bin" --flash_mode dio --flash_freq 80m --flash_size 16MB \
    0x2000 "$loader/bootloader/bootloader.bin" \
    0x8000 "$loader/partition_table/partition-table.bin" \
    0x10000 "$out/nihos-native.bin" >> "$out/image.log" 2>&1
python3 "$root/probes/wamr-native/check-image.py" "$out/nihos-native-image.elf" \
    "$out/app.wasm" "$out/app-test-ed25519.nihpkg" "$out/app-update-ed25519.nihpkg" \
    "$out/image-audit-wamr.json"
"${riscv_cc%gcc}nm" "$out/nihos-native.elf" > "$out/symbols.txt"
if grep -q ' nih_wamr_call$' "$out/symbols.txt"; then
    echo 'Task image retained the boot-only SP-switch entry' >&2; exit 1
fi
emulator=$(sh "$root/tools/bootstrap-esp-emu.sh")
python3 - "$emulator" "$out" <<'PY'
import hashlib,json,re,subprocess,sys
from pathlib import Path
emulator,out=sys.argv[1],Path(sys.argv[2])
files=('nihos-native-image.elf','nihos-native-flash.bin')
identity={f:hashlib.sha256((out/f).read_bytes()).hexdigest() for f in files}
cases=[]
for name,injected,status,calls,uart_status,received,frames in (
    ('normal','0x10q',0,17,1,5,3),
    ('noinput','',42,11,2,0,0),
    ('early-quit','q',44,11,1,1,0),
):
    cmd=[emulator,'--chip','esp32p4','--firmware',str(out/files[1]),'--elf',str(out/files[0]),
         '--psram-size','4M','--timeout','60s','--exit-on','NIHOS_WASM_TASK_DONE']
    if injected:cmd+=['--inject',injected,'--inject-on','NIHOS_WAMR_UART_READY']
    result=subprocess.run(cmd,capture_output=True,text=True,timeout=65)
    (out/f'{name}.log').write_text(result.stdout)
    (out/f'{name}-stderr.log').write_text(result.stderr)
    assert result.returncode==0,(name,result.returncode)
    assert 'NIHOS_NATIVE_FAIL' not in result.stdout,result.stdout
    rows=re.findall(r'^NIHOS_WASM_TASK (.+)$',result.stdout,re.M)
    assert len(rows)==2,rows
    records=[{k:int(v,16) for k,v in (field.split('=') for field in row.split())} for row in rows]
    for index,record in enumerate(records):
        expected={'round':index+1,'status':status if index==0 else 0,'reaped':1,'guards':1,'recovered':1,'released':1,
                  'calls':calls if index==0 else 17,'uart_status':uart_status if index==0 else 1,
                  'uart_bytes':received if index==0 else 5,'uart_frames':frames if index==0 else 3,
                  'owner_checks':15,'owners_released':1,'surface_checks':127 if index or status==0 else 95}
        assert all(record[k]==v for k,v in expected.items()),(record,expected)
        assert all(record[k]>0 for k in ('captures','timers','waits','ticks0','ticks1')),record
        assert 0<record['stack_used']<65536 and record['charged']>=record['requested']==499712,record
    assert records[1]['generation']>records[0]['generation'] and records[1]['reused']==1,records
    assert all(hashlib.sha256((out/f).read_bytes()).hexdigest()==h for f,h in identity.items())
    cases.append({'case':name,'external_input':injected,'rounds':records})
    print(f'normal WAMR task {name}: captured, waited, reaped, pinned backing recovered',flush=True)
(out/'task-report.json').write_text(json.dumps({'evidence':'headless RV32 emulator; no physical run',
    'candidate':identity,'cases':cases},indent=2)+'\n')
PY
