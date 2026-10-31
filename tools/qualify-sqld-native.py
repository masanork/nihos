#!/usr/bin/env python3
"""Exclusive native sqld install and Scheme -> SD -> warm-reboot proof.

MicroSD provisioning is enabled only by a separately built matching CID image.
Requires an explicit --install. Saves a fresh private complete Flash backup.
"""
import argparse
import contextlib
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import subprocess
import time
import normal_fs_manifest
import sqld_native_manifest
from native_serial import capture_serial_class, disable_hangup
ROOT=Path(__file__).resolve().parents[1]
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('port');parser.add_argument('build',type=Path);parser.add_argument('output',type=Path)
    parser.add_argument('--backup-from',type=Path,help='complete expected Flash bytes from a verified prior phase; verify every byte before reusing');parser.add_argument('--install',action='store_true');parser.add_argument('--exercise',action='store_true');parser.add_argument('--readback',action='store_true')
    a=parser.parse_args();build=a.build.resolve()
    fs=json.loads((build/'normal-fs-manifest.json').read_text());sql=json.loads((build/'sqld-manifest.json').read_text())
    normal_fs_manifest.verify_files(build,fs);sqld_native_manifest.verify(build,sql)
    report=runpy.run_path(str(ROOT/'tools/check-native-image.py'))['audit']((build/'nihos-native.elf').read_bytes(),(build/'nihos-native.bin').read_bytes(),'integer','device',normal_fs_manifest=fs,sqld_manifest=sql)
    if 'pub const xy_trace = true;' not in (build/'native_options.zig').read_text():raise ValueError('trace candidate required')
    if (a.exercise or a.readback) and sql['provision_cid']!=0:raise ValueError('exercise requires ordinary image with provisioning disabled')
    out=a.output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
    shutil.copyfile(__file__,out/'qualification-tool.py')
    frozen=out/'candidate';frozen.mkdir(mode=0o700)
    paths={'0x2000':build/'loader/bootloader/bootloader.bin','0x8000':build/'loader/partition_table/partition-table.bin','0x10000':build/'nihos-native.bin'}
    for address,path in list(paths.items()):
        target=frozen/path.name;shutil.copyfile(path,target)
        if sha(target)!=sha(path):raise RuntimeError('candidate changed while freezing')
        paths[address]=target
    for name in ('nihos-native.elf','normal-fs-manifest.json','sqld-manifest.json','native_options.zig','image-audit.json'):shutil.copyfile(build/name,frozen/name)
    result={'passed':False,'source_base':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'candidate':{p.name:sha(p) for p in frozen.iterdir()},'sqld':report['sqld'],'observations':[],'physical_power_cut_tested':False}
    save=lambda:(out/'result.json').write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n')
    save()
    import serial,esptool
    from esptool.reset import HardReset
    spec=importlib.util.spec_from_file_location('usb',ROOT/'tools/capture-native-usb.py');usb=importlib.util.module_from_spec(spec);spec.loader.exec_module(usb)
    lock_path='/tmp/nihos-tab5-e8f60ae2e89c-write.lock'
    lock=int(os.environ['NIHOS_DEVICE_LOCK_FD']) if 'NIHOS_DEVICE_LOCK_FD' in os.environ else os.open(lock_path,os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    if (os.fstat(lock).st_dev,os.fstat(lock).st_ino)!=(os.stat(lock_path).st_dev,os.stat(lock_path).st_ino):raise RuntimeError('inherited device lock differs')
    try:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        owners=subprocess.run(['lsof','-t',a.port,a.port.replace('/cu.','/tty.')],capture_output=True,text=True)
        if owners.returncode not in (0,1) or owners.stdout.strip():raise RuntimeError('serial is owned')
        with capture_serial_class(serial.Serial)(a.port,115200,timeout=.1,exclusive=True) as port:
            disable_hangup(port)
            with (out/'identity.log').open('w') as log,contextlib.redirect_stdout(log),contextlib.redirect_stderr(log):
                device=esptool.detect_chip(port=port,baud=115200)
                mac=':'.join(f'{n:02x}' for n in device.read_mac());chip=device.get_chip_description();flash=device.flash_id()
            if mac!='e8:f6:0a:e2:e8:9c' or not chip.startswith('ESP32-P4') or flash>>16!=0x18:raise RuntimeError('unexpected device')
            result['device']={'mac':mac,'chip':chip,'flash_id':flash};save()
            print('Exclusive Tab5 ownership and chip identity confirmed',flush=True)
            if a.install:
                backup=out/'backup-flash-16MiB.bin'
                if a.backup_from:
                    if a.backup_from.stat().st_size!=16*1024*1024:raise ValueError('backup must be complete')
                    print('Verifying complete expected Flash before reusing backup',flush=True)
                    usb.tool(port,out/'verify-complete-before.log','verify_flash',{'0x0':a.backup_from.resolve()})
                    shutil.copyfile(a.backup_from,backup)
                else:
                    print('Saving a fresh private 16 MiB Flash backup',flush=True)
                    with (out/'backup.log').open('w') as log,contextlib.redirect_stdout(log),contextlib.redirect_stderr(log):
                        esptool.main(['--chip','esp32p4','--baud','460800','--after','no_reset','read_flash','0','0x1000000',str(backup)],esp=device)
                if backup.stat().st_size!=16*1024*1024:raise RuntimeError('incomplete backup')
                expected=bytearray(backup.read_bytes())
                for address,path in paths.items():
                    at=int(address,0);data=path.read_bytes()
                    first=at&~4095;last=(at+len(data)+4095)&~4095
                    expected[first:last]=b'\xff'*(last-first);expected[at:at+len(data)]=data
                (out/'expected-flash-16MiB.bin').write_bytes(expected)
                result['backup_sha256']=sha(backup);save()
                print('Installing frozen candidate',flush=True);usb.tool(port,out/'install.log','write_flash',paths)
            usb.tool(port,out/'verify-before.log','verify_flash',paths)
            raw=bytearray()
            with (out/'capture.log').open('wb') as capture:
                def wait(predicate,seconds=60):
                    until=time.monotonic()+seconds
                    while time.monotonic()<until:
                        data=port.read(max(1,port.in_waiting))
                        if data:raw.extend(data);capture.write(data);capture.flush()
                        if b'NIHOS_NATIVE_FAIL' in raw:raise RuntimeError('native fault')
                        found=predicate(raw)
                        if found is not None:return found
                    raise TimeoutError('bounded sqld phase timed out')
                def record(data,marker):
                    matches=re.findall(rb'(?m)^'+marker+rb' ([^\r\n]+)\r?\n',data)
                    return {k.decode():int(v,16) for k,v in re.findall(rb'(\w+)=([0-9a-f]{8})(?:\s|$)',matches[-1])} if matches else None
                def boot():
                    raw.clear();port.reset_input_buffer();port.dtr=False;HardReset(port,uses_usb=True)()
                    row=wait(lambda b:(r if r and r['phase'] in (2,3,4) else None) if (r:=record(b,b'NIHOS_NATIVE_SQLD')) else None,90)
                    result['observations'].append({'name':'boot',**row});save();print('sqld boot '+str(row),flush=True)
                    return row
                row=boot()
                if sql['provision_cid'] != 0 and row['phase'] != 2:raise RuntimeError('CID provisioning did not produce a ready service')
                if a.exercise or a.readback:
                    if row['phase']!=2:raise RuntimeError('sqld not ready')
                    def evaluate(source,expected=None):
                        start=len(raw)
                        previous=record(raw,b'NIHOS_NATIVE_XY_STATE')
                        target=(previous['input_bytes'] if previous else 0)+len(source.encode())+2
                        port.write(b'\x1b');port.flush();time.sleep(.15)
                        port.write(source.encode()+b'\r');port.flush()
                        def completed(data):
                            tail=data[start:]
                            states=list(re.finditer(rb'(?m)^NIHOS_NATIVE_XY_STATE [^\r\n]+\r?\n',tail))
                            if not states:return None
                            match=states[-1];state=record(match.group(),b'NIHOS_NATIVE_XY_STATE')
                            if state['input_bytes']<target or state['status'] not in (5,6):return None
                            replies=re.findall(rb'NIHOS_NATIVE_XY_REPLY data=([0-9a-f]*)\r?\n',tail[match.end():])
                            return (bytes.fromhex(replies[0].decode()).decode(),state) if replies else None
                        reply,state=wait(completed)
                        if state['status']!=5:raise RuntimeError(source+' => '+reply+' '+str(state))
                        if expected is not None and reply!=expected:raise RuntimeError(source+' => '+reply+' expected '+expected)
                        result['observations'].append({'name':'scheme','source':source,'reply':reply,'state':state});save();print(source+' => '+reply,flush=True)
                        return reply
                    if a.exercise:
                        evaluate('(sql/exec! "CREATE TABLE IF NOT EXISTS native_probe(id PRIMARY KEY,body)")')
                        evaluate('(sql/exec! "INSERT OR REPLACE INTO native_probe VALUES(1,\'before\')")')
                        evaluate('(buffer/insert! "日本語 source")');evaluate('(buffer/save! "native-source.scm")')
                        evaluate('(define snap (fs/snapshot))')
                        evaluate('(sql/exec! "UPDATE native_probe SET body=\'after\'")')
                        evaluate('(sql/query "SELECT body FROM native_probe")','(("after"))')
                        evaluate('(fs/restore! snap)');evaluate('(fs/release! snap)')
                        evaluate('(sql/query "SELECT body FROM native_probe")','(("before"))')
                        evaluate('(sql/begin!)');evaluate('(sql/exec! "UPDATE native_probe SET body=\'rollback\'")');evaluate('(sql/rollback!)')
                        evaluate('(sql/query "SELECT body FROM native_probe")','(("before"))')
                        evaluate('(fs/begin!)');evaluate('(define f (fs/open "temporary" #t))');evaluate('(fs/write! f 0 (list 0 255 1))','3');evaluate('(fs/rollback!)')
                        evaluate('(fs/collect!)');evaluate('(sql/check)','(("ok"))');evaluate('(fs/space)')
                        row=boot()
                        if row['phase']!=2:raise RuntimeError('reboot mount failed')
                    evaluate('(sql/query "SELECT body FROM native_probe")','(("before"))')
                    evaluate('(buffer/load! "native-source.scm")');evaluate('(buffer/text)','"日本語 source"')
                    evaluate('(define f (fs/open "native-source.scm"))');evaluate('(fs/verify f)');evaluate('(fs/close! f)')
                    evaluate('(sql/check)','(("ok"))');evaluate('(fs/generation)')
                    start=len(raw);deadline=time.monotonic()+10
                    while time.monotonic()<deadline:
                        data=port.read(max(1,port.in_waiting));raw.extend(data);capture.write(data)
                    idle=record(raw[start:],b'NIHOS_NATIVE_XY_IDLE')
                    if not idle or idle['dma_error']!=0:raise RuntimeError('display idle not healthy')
                    result['observations'].append({'name':'idle',**idle});result['warm_reboot_readback']=True;save()
            usb.tool(port,out/'verify-after.log','verify_flash',paths)
            if a.install:usb.tool(port,out/'verify-complete-after.log','verify_flash',{'0x0':out/'expected-flash-16MiB.bin'})
            result['passed']=True;save();print('Physical native sqld phase passed',flush=True)
    finally:os.close(lock)
if __name__=='__main__':main()
