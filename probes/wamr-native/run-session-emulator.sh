#!/bin/sh
# Common Session with synchronous frame RPC to the real scheduled WAMR worker.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
out=${NIHOS_WASM_SESSION_OUT:-"$root/build/wasm-session-emulator"}
riscv_cc=${NIHOS_RISCV_CC:-riscv32-esp-elf-gcc}
python=${NIHOS_IDF_PYTHON:-python3}
loader="$root/build/native-emulator/loader"
mkdir -p "$out"
NIHOS_NATIVE_WASM_SESSION_TEST=1 NIHOS_NATIVE_WASM_TASK=1 NIHOS_NATIVE_BOOT_TEST=1 \
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
    "$out/image-audit-wamr.json" --session
"${riscv_cc%gcc}nm" "$out/nihos-native.elf" > "$out/symbols.txt"
if grep -q ' nih_wamr_call$' "$out/symbols.txt"; then
    echo 'Session image retained the boot SP-switch entry' >&2; exit 1
fi
emulator=$(sh "$root/tools/bootstrap-esp-emu.sh")
python3 - "$emulator" "$out" <<'PY'
import hashlib,json,os,re,subprocess,sys
from pathlib import Path
emulator,out=sys.argv[1],Path(sys.argv[2])
files=('nihos-native-image.elf','nihos-native-flash.bin')
identity={f:hashlib.sha256((out/f).read_bytes()).hexdigest() for f in files}
cases=[]
for name,injected,status,received,frames,presentations,rejected in (
    ('normal','0x10q',0,5,3,4,1),('noinput','',-42,0,0,1,0),
    ('early-quit','q',-44,1,0,1,0),('cancel','c',-45,1,0,1,0),
    ('metered-trap','t',-48,1,0,1,0),('present-failure','p',-49,1,0,1,0),
):
    cmd=[emulator,'--chip','esp32p4','--firmware',str(out/files[1]),'--elf',str(out/files[0]),
         '--psram-size','4M','--timeout','60s','--exit-on','NIHOS_WASM_SESSION_DONE']
    if injected:cmd+=['--inject',injected,'--inject-on','NIHOS_WASM_SESSION_READY']
    result=subprocess.run(cmd,capture_output=True,text=True,timeout=65)
    (out/f'{name}.log').write_text(result.stdout)
    (out/f'{name}-stderr.log').write_text(result.stderr)
    assert result.returncode==0,(name,result.returncode)
    assert 'NIHOS_NATIVE_FAIL' not in result.stdout,result.stdout
    assert len(re.findall(r'^NIHOS_WASM_ASYNC_PASS$',result.stdout,re.M))==1,result.stdout
    if os.environ.get('NIHOS_NATIVE_WASM_ALIGN_CORPUS') == '1':
        assert len(re.findall(r'^NIHOS_WAMR_CORPUS_PASS$',result.stdout,re.M)) >= 2,result.stdout
    async_rows=re.findall(r'^NIHOS_WASM_ASYNC turns=([0-9a-f]+) begin_us=([0-9a-f]+)$',result.stdout,re.M)
    # Emulator-only guard against returning to the seconds-long synchronous open.
    assert len(async_rows)==1 and int(async_rows[0][0],16)>1 and 0<int(async_rows[0][1],16)<100000,async_rows
    rows=re.findall(r'^NIHOS_WASM_SESSION (.+)$',result.stdout,re.M)
    assert len(rows)==2,rows
    records=[{k:int(v,16) for k,v in (field.split('=') for field in row.split())} for row in rows]
    assert len(re.findall(r'^NIHOS_WASM_SESSION_PARTIAL recovered=00000001 ',result.stdout,re.M))==1,result.stdout
    for i,r in enumerate(records):
        expected={'round':i+1,'status':(status if i==0 else 0)&0xffffffff,
                  'bytes':received if i==0 else 5,'frames':frames if i==0 else 3,
                  'presentations':presentations if i==0 else 4,'rejected':rejected if i==0 else 1,
                  'recovered':1,'reaped':1,'wiped':1,'detached':1,'guards':1,
                  'calls':8 if i or name=='normal' else 4 if name=='present-failure' else 2,
                  'denied':4 if i or name=='normal' else 2 if name in ('metered-trap','present-failure') else 1,
                  'requested':532480,'charged':589824}
        assert all(r[k]==v for k,v in expected.items()),(name,r,expected)
        assert all(r[k]>0 for k in ('captures','timers','waits','calls','denied','ticks0','ticks1','open_us','render_max_us','close_us')),r
        assert 0<r['stack_used']<65536,r
    assert records[1]['generation']>records[0]['generation']+1,records
    assert all(hashlib.sha256((out/f).read_bytes()).hexdigest()==h for f,h in identity.items())
    cases.append({'case':name,'external_input':injected,'restart_input':'synthetic 0x10q',
                  'async':{'turns':int(async_rows[0][0],16),'begin_us':int(async_rows[0][1],16)},'rounds':records})
    print(f'Wasm common session {name}: pixel oracle, task reap, wipe and restart passed',flush=True)
(out/'report.json').write_text(json.dumps({'evidence':'headless RV32 common session; no scanout or physical run',
    'candidate':identity,'cases':cases},indent=2)+'\n')
PY
