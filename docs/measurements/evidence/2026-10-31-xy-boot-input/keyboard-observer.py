import fcntl,json,os,re,subprocess,sys,time
from pathlib import Path
sys.path.insert(0,'tools')
import serial
from native_serial import capture_serial_class,disable_hangup
out=Path('build/xy-boot-keyboard');out.mkdir(exist_ok=True)
lock=open('/tmp/nihos-tab5-e8f60ae2e89c-write.lock','a+');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
r=subprocess.run(['lsof','-t','/dev/cu.usbmodem101','/dev/tty.usbmodem101'],capture_output=True,text=True)
assert r.returncode in (0,1) and not r.stdout.strip(), 'serial busy'
Port=capture_serial_class(serial.Serial);Port.passive_open=True
records=[];pending=bytearray();baseline=None
result={'physical_input_transport':'Tab5 I2C keyboard','serial_writes_hex':'0c','observations':records,'baseline_captured':False,'native_fault':False}
with (out/'capture.log').open('wb') as log,Port('/dev/cu.usbmodem101',115200,timeout=.1,exclusive=True) as p:
 disable_hangup(p);p.write(b'\x0c');p.flush()
 until=time.monotonic()+180
 while time.monotonic()<until:
  b=p.read(max(1,p.in_waiting));log.write(b);pending.extend(b)
  if b'NIHOS_NATIVE_FAIL' in pending:result['native_fault']=True;raise RuntimeError('native fault')
  while b'\n' in pending:
   line,_,pending=pending.partition(b'\n')
   if b'NIHOS_NATIVE_XY_STATE ' not in line:continue
   line=line.split(b'NIHOS_NATIVE_XY_STATE ',1)[1]
   row={k.decode():int(v,16) for k,v in re.findall(rb'(\w+)=([0-9a-f]{8})(?:\s|$)',line)}
   if not all(k in row for k in ('revision','bytes','cursor','fnv','mode','input_bytes','status')):continue
   if records and row['revision']==records[-1]['revision']:continue
   row['elapsed_seconds']=round(180-(until-time.monotonic()),3)
   records.append(row)
   if baseline is None:
    baseline=row;result['baseline_captured']=True
    print('BASELINE; no more serial writes',row,flush=True)
   else:print('PHYSICAL INPUT STATE',row,flush=True)
   (out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print('OBSERVATION COMPLETE',flush=True)
lock.close()
