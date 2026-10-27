#!/usr/bin/env python3
"""Capture automatic-card events under one serial lease; never enters a PIN."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import time

SPEC=importlib.util.spec_from_file_location('usb_capture',Path(__file__).with_name('capture-native-usb.py'))
USB=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(USB)
def main():
    import serial
    from esptool.reset import HardReset
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('port');p.add_argument('output',type=Path);p.add_argument('audit',type=Path)
    p.add_argument('--install',type=Path);p.add_argument('--prior',type=Path,help='retained installation to verify before replacement')
    p.add_argument('--seconds',type=int,default=600);p.add_argument('--jobs',type=int,default=3)
    p.add_argument('--kinds',default='1,2,4');p.add_argument('--require-removal',action='store_true')
    a=p.parse_args()
    if not 1<=a.jobs<=10 or not 10<=a.seconds<=1800:p.error('jobs 1..10, seconds 10..1800 required')
    audit=json.loads(a.audit.read_text());profile=audit.get('automatic_cards')
    if not profile:p.error('automatic-card image audit required')
    a.output.mkdir(parents=True,exist_ok=False)
    paths=None
    if a.install:paths,a.audit=USB.snapshot_install(a.install,a.audit,a.output)
    with serial.Serial(a.port,115200,timeout=.15,exclusive=True) as console:
        print('Exclusive automatic-card lease acquired',flush=True)
        if a.prior:
            USB.tool(console,a.output/'verify-prior.log','verify_flash',{k:a.prior/n for k,n in [('0x2000','bootloader.bin'),('0x8000','partition-table.bin'),('0x10000','nihos-native.bin')]})
        if paths:
            USB.tool(console,a.output/'flash.log','write_flash',paths)
            USB.tool(console,a.output/'verify-before.log','verify_flash',paths)
        console.dtr=False;console.reset_input_buffer();HardReset(console,uses_usb=True)()
        data=bytearray();announced=set();start=time.monotonic();completed=None
        with (a.output/'boot.raw.log').open('wb') as out:
            while time.monotonic()-start<a.seconds:
                chunk=console.read(max(1,console.in_waiting))
                if chunk:data.extend(chunk);out.write(chunk);out.flush()
                text=data.decode('ascii',errors='replace').replace('\r','')
                for line in text.splitlines():
                    if line.startswith(('NIHOS_NATIVE_CARD_AUTO_BOOT ','NIHOS_NATIVE_CARD_AUTO_DETECTED ','NIHOS_NATIVE_CARD_AUTO_SELECTED ','NIHOS_NATIVE_CARD_AUTO_PROMPT ','NIHOS_NATIVE_CARD_AUTO_RESULT ','NIHOS_NATIVE_CARD_AUTO_DONE ','NIHOS_NATIVE_CARD_AUTO_REMOVED ','NIHOS_NATIVE_CARD_AUTO_ABORT ')) and line not in announced:
                        print(line,flush=True);announced.add(line)
                marker='NIHOS_NATIVE_CARD_AUTO_DONE ' if profile['read_enabled'] else 'NIHOS_NATIVE_CARD_AUTO_DETECTED '
                count=text.count(marker)
                removed=text.count('NIHOS_NATIVE_CARD_AUTO_REMOVED ')
                if ('NIHOS_NATIVE_FAIL ' in text or count>=a.jobs and (not a.require_removal or removed>=a.jobs)) and completed is None:completed=time.monotonic()
                if completed is not None and time.monotonic()-completed>1:break
        first=data.find(b'ESP-ROM:esp32p4');(a.output/'boot.log').write_bytes(data[first:] if first>=0 else data)
        if count<a.jobs or a.require_removal and removed<a.jobs:
            raise SystemExit('Requested job/removal count not reached; retained logs; no completion marker')
        result=subprocess.run([sys.executable,str(Path(__file__).with_name('check-native-auto-log.py')),str(a.output/'boot.log'),str(a.audit),str(a.output/'report.json'),'--kinds',a.kinds])
        if result.returncode:raise SystemExit('Automatic-card qualification failed; retained logs; no post-failure reset')
        # No reset of an interactive app on lease release. A separate explicit
        # verification can be requested after all local viewing has finished.
        (a.output/'exclusive-complete.json').write_text(json.dumps({'jobs':a.jobs,'probe_only':not profile['read_enabled'],'exclusive_descriptor_held':True,'installed':bool(paths),'preverify':bool(paths),'postverify':False},indent=2)+'\n')
        print('Requested automatic-card observations passed; serial lease released',flush=True)
if __name__=='__main__':main()
