#!/bin/sh
# Execute the real normal-profile session backend; no physical display claim.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
out="$root/build/rust-session-emulator"
mkdir -p "$out"
NIHOS_NATIVE_BOOT_TEST=1 NIHOS_NATIVE_RUST_SESSION_TEST=1 \
    sh "$root/tools/build-native.sh" emulator integer > "$out/build.log" 2>&1 || {
    cat "$out/build.log"; exit 1;
}
for file in nihos-native.elf nihos-native.bin nihos-native-flash.bin image-audit.json native_options.zig; do
    cp "$root/build/native-emulator/$file" "$out/"
done
emulator=$(sh "$root/tools/bootstrap-esp-emu.sh")
python3 - "$emulator" "$out" <<'PY'
import hashlib,json,re,subprocess,sys
from pathlib import Path
emulator,out=sys.argv[1],Path(sys.argv[2])
names=('nihos-native.elf','nihos-native-flash.bin')
identity={name:hashlib.sha256((out/name).read_bytes()).hexdigest() for name in names}
cases=[]
for name,injected,status,received,frames,presentations,rejected in (
    ('normal','0x10q',0,5,3,4,1),
    ('noinput','',-42,0,0,1,0),
    ('early-quit','q',-44,1,0,1,0),
):
    command=[emulator,'--chip','esp32p4','--firmware',str(out/names[1]),
             '--elf',str(out/names[0]),'--psram-size','4M','--timeout','30s',
             '--exit-on','NIHOS_RUST_SESSION_DONE']
    if injected: command+=['--inject',injected,'--inject-on','NIHOS_RUST_SESSION_READY']
    result=subprocess.run(command,capture_output=True,text=True,timeout=35,check=True)
    (out/f'{name}.log').write_text(result.stdout)
    (out/f'{name}-stderr.log').write_text(result.stderr)
    assert 'NIHOS_NATIVE_FAIL' not in result.stdout,result.stdout
    assert len(re.findall(r'^NIHOS_RUST_SESSION_READY$',result.stdout,re.M))==1
    records=re.findall(r'^NIHOS_NATIVE_RUST_SESSION (.+)$',result.stdout,re.M)
    assert len(records)==1,records
    fields={k:int(v,16) for k,v in (field.split('=') for field in records[0].split())}
    expected={'status':status&0xffffffff,'bytes':received,'input_frames':frames,
              'presentations':presentations,'rejected':rejected,'released':1}
    assert all(fields[k]==v for k,v in expected.items()),(fields,expected)
    assert fields['requested']==32768 and fields['charged']>=32768,fields
    assert fields['free_before']==fields['free_after'],fields
    assert fields['ticks0']>0 and fields['ticks1']>0,fields
    assert all(hashlib.sha256((out/n).read_bytes()).hexdigest()==h for n,h in identity.items())
    cases.append({'case':name,**fields})
    print(f'normal-profile Rust session {name}: recovered; both hart timers advanced',flush=True)
(out/'report.json').write_text(json.dumps({'evidence':'headless emulator; no scanout',
    'candidate':identity,'cases':cases},indent=2)+'\n')
PY
