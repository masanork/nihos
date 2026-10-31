#!/bin/sh
# Emulator UART -> normal UI poll/decoder/dispatcher -> WAMR. No LCD scanout.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
out="$root/build/wasm-interactive-repeat"
riscv_cc=${NIHOS_RISCV_CC:-riscv32-esp-elf-gcc}
python=${NIHOS_IDF_PYTHON:-python3}
loader="$root/build/native-emulator/loader"
mkdir -p "$out"
NIHOS_NATIVE_WASM_INTERACTIVE_REPEAT=1 NIHOS_NATIVE_WASM_INTERACTIVE=1 NIHOS_NATIVE_WASM_SESSION_TEST=1 NIHOS_NATIVE_WASM_TASK=1 NIHOS_NATIVE_BOOT_TEST=1 \
    sh "$root/tools/build-native-elf.sh" emulator "$out" wasm > "$out/build.log" 2>&1 || { cat "$out/build.log"; exit 1; }
"${riscv_cc%gcc}objcopy" --strip-debug "$out/nihos-native.elf" "$out/nihos-native-image.elf"
"$python" -m esptool --chip esp32p4 elf2image --use_segments --flash_mode dio --flash_freq 80m --flash_size 16MB \
    --min-rev-full 300 --max-rev-full 399 --elf-sha256-offset 0xb0 -o "$out/nihos-native.bin" "$out/nihos-native-image.elf" > "$out/image.log" 2>&1
"$python" -m esptool --chip esp32p4 merge_bin -o "$out/nihos-native-flash.bin" --flash_mode dio --flash_freq 80m --flash_size 16MB \
    0x2000 "$loader/bootloader/bootloader.bin" 0x8000 "$loader/partition_table/partition-table.bin" 0x10000 "$out/nihos-native.bin" >> "$out/image.log" 2>&1
python3 "$root/probes/wamr-native/check-image.py" "$out/nihos-native-image.elf" "$out/app.wasm" "$out/app-test-ed25519.nihpkg" "$out/app-update-ed25519.nihpkg" "$out/image-audit.json" --session
emulator=$(sh "$root/tools/bootstrap-esp-emu.sh")
python3 - "$emulator" "$out" <<'PYRUN'
import hashlib,json,re,subprocess,sys
from pathlib import Path
emu,out=sys.argv[1],Path(sys.argv[2]); names=('nihos-native-image.elf','nihos-native-flash.bin')
hashes={name:hashlib.sha256((out/name).read_bytes()).hexdigest() for name in names}
def marker(round,state): return f'NIHOS_WASM_REPEAT round={round:08x} state={state:08x}'
steps=[('\x1b','NIHOS_WASM_INTERACTIVE_READY'),('rust-app\r','NIHOS_NATIVE_SESSION_VIEW'),
       ('010',marker(1,1)),('q','NIHOS_WASM_WORK_ACTIVE round=00000001'),('rust-app\r',marker(1,2)),('q',marker(2,5)),
       ('rust-app\r',marker(2,4)),('010',marker(3,1)),('q','NIHOS_WASM_WORK_ACTIVE round=00000003')]
cmd=[emu,'--chip','esp32p4','--firmware',str(out/names[1]),'--elf',str(out/names[0]),'--psram-size','4M','--timeout','90s','--exit-on',marker(3,2)]
for payload,trigger in steps: cmd+=['--inject',payload,'--inject-on',trigger]
r=subprocess.run(cmd,capture_output=True,text=True,timeout=100)
(out/'repeat.log').write_text(r.stdout); (out/'repeat-stderr.log').write_text(r.stderr)
assert r.returncode==0 and 'NIHOS_NATIVE_FAIL' not in r.stdout,(r.returncode,r.stdout)
rows=re.findall(r'NIHOS_WASM_REPEAT round=([0-9a-f]+) state=([0-9a-f]+) frames=([0-9a-f]+) signature=([0-9a-f]+)',r.stdout)
rows=[tuple(int(x,16) for x in row) for row in rows]
assert rows==[(1,5,0,0),(1,1,0,0),(1,2,4,4),(2,5,0,0),(2,4,0,0),(3,5,0,0),(3,1,0,0),(3,2,4,4)],rows
fg=re.findall(r'NIHOS_WASM_FOREGROUND round=([0-9a-f]+) opening=([0-9a-f]+) cancelling=([0-9a-f]+) active=([0-9a-f]+) max_gap_us=([0-9a-f]+)',r.stdout)
fg=[tuple(int(x,16) for x in row) for row in fg]
assert len(fg)==3 and [x[0] for x in fg]==[1,2,3],fg
assert all(row[1]>0 and 0<row[4]<200000 for row in fg),fg
assert fg[0][1]>1 and fg[2][1]>1,fg
assert fg[0][3]>=25 and fg[1][2]>0 and fg[2][3]>=25,fg
work=re.findall(r'NIHOS_WASM_WORK round=([0-9a-f]+) items=([0-9a-f]+) digest=([0-9a-f]+) sensor=([0-9a-f]+)',r.stdout)
work=[tuple(int(x,16) for x in row) for row in work]
def expected(round,items):
    digest=2166136261; sensor=0
    for seq in range(1,items+1):
        for i in range(64): digest=((digest ^ ((seq*17+i*29+round*7)&255))*16777619)&0xffffffff
        sensor=(sensor+sum((seq*31+i*7+round*11)&1023 for i in range(16)))&0xffffffff
    return digest,sensor
assert len(work)==3 and [w[0] for w in work]==[1,2,3],work
for row,phase in zip(work,fg):
    assert row[1]==sum(phase[1:4]) and row[1]>0 and row[2:]==expected(row[0],row[1]),(row,phase)
hosted=re.findall(r'NIHOS_WASM_HOSTED_FIXTURE round=([0-9a-f]+) accepted=([0-9a-f]+) rejected=([0-9a-f]+) errors=([0-9a-f]+) active_events=([0-9a-f]+)',r.stdout)
hosted=[tuple(int(x,16) for x in row) for row in hosted]
assert len(hosted)==3 and [h[0] for h in hosted]==[1,2,3],hosted
for h,w in zip(hosted,work):
    n=w[1]; assert h[1]==n//4+(n%4>=2) and h[2]==n//4 and h[3]==0,(h,w)
assert hosted[0][4]>0 and hosted[2][4]>0 and hosted[1][4]==0,hosted
station=re.findall(r'NIHOS_WASM_STATION_FIXTURE round=([0-9a-f]+) completed=([0-9a-f]+) stale=([0-9a-f]+) errors=([0-9a-f]+) offers=([0-9a-f]+) corrupt=([0-9a-f]+) opening=([0-9a-f]+) cancelling=([0-9a-f]+) active=([0-9a-f]+)',r.stdout)
station=[tuple(int(x,16) for x in row) for row in station]
assert len(station)==3 and [v[0] for v in station]==[1,2,3],station
for v,w in zip(station,work):
    n=w[1]; assert v[1]==n//17 and v[2]==(n+13)//17 and v[3]==0 and v[4]==(n+3)//17 and v[5]==(n+1)//17 and sum(v[6:])==v[1],(v,w)
assert station[0][6]>0 and station[0][8]>0 and station[1][7]>0 and station[2][6]>0 and station[2][8]>0,station
latency=re.findall(r'NIHOS_WASM_REQUEST_LATENCY round=([0-9a-f]+) render_us=([0-9a-f]+) close_us=([0-9a-f]+)',r.stdout)
latency=[tuple(int(x,16) for x in row) for row in latency]
assert len(latency)==3 and [x[0] for x in latency]==[1,2,3],latency
assert all(0<latency[i][1]<200000 and 0<latency[i][2]<200000 for i in (0,2)),latency
assert latency[1][1:]==(0,0),latency
assert r.stdout.count('Starting Rust sample; q or Esc cancels.')==3,r.stdout
assert r.stdout.count('Rust sample stopped.\nnihos> ')==3,r.stdout
assert all(hashlib.sha256((out/f).read_bytes()).hexdigest()==h for f,h in hashes.items())
(out/'report.json').write_text(json.dumps({'scope':'single RV32 emulator boot, ROM UART through actual UI poll and decoder; substituted shell storage and pixel presenter, no hardware scanout','candidate':hashes,'events':[dict(zip(('round','state','frames','signature'),row)) for row in rows], 'foreground':[dict(zip(('round','opening','cancelling','active','max_gap_us'),row)) for row in fg], 'mock_work':[dict(zip(('round','items','digest','sensor'),row)) for row in work], 'hosted_decoder':[dict(zip(('round','accepted','rejected','errors','active_events'),row)) for row in hosted], 'request_latency':[dict(zip(('round','render_us','close_us'),row)) for row in latency], 'hosted_station':[dict(zip(('round','completed','stale','errors','offers','corrupt','opening','cancelling','active'),row)) for row in station]},indent=2)+'\n')
print('repeat: two active runs and startup cancellation, with shell returns and full recovery passed')
PYRUN
