#!/usr/bin/env python3
"""Install and qualify the bounded Tab5 reader, preserving a private full Flash backup.

The write lock and kernel serial lease cover identity, backup, install, readback and
all inputs. No SD writes. On failure, restore each erased Flash span from backup.
Successful runs leave the requested reader installed and a book open.
"""
import argparse, contextlib, fcntl, hashlib, importlib.util, json, os
from pathlib import Path
import re, shutil, subprocess, time
ROOT=Path(__file__).resolve().parents[1]
SHA=lambda data:hashlib.sha256(data).hexdigest()

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('port');ap.add_argument('build',type=Path);ap.add_argument('output',type=Path)
    ap.add_argument('--leave-book',choices=('grass','sicp'),default='grass',help='Book to leave open in vertical writing after qualification')
    ap.add_argument('--install',action='store_true');ap.add_argument('--backup-from',type=Path,help='Reuse a private full backup only after whole-Flash verification');args=ap.parse_args()
    if not args.install:ap.error('--install is required; this command replaces firmware after backup')
    import serial,esptool
    from esptool.reset import HardReset
    from native_serial import capture_serial_class,disable_hangup
    build=args.build.resolve();out=args.output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
    audit=json.loads((build/'image-audit.json').read_text())
    app=(build/'nihos-native.bin').read_bytes();elf=(build/'nihos-native.elf').read_bytes()
    if audit['memory']['profile']!='device' or SHA(app)!=audit['image_sha256'] or SHA(elf)!=audit['elf_sha256']:raise RuntimeError('candidate audit identity mismatch')
    if len(app)>4*1024*1024 or 'pub const xy_trace = true;' not in (build/'native_options.zig').read_text():raise RuntimeError('need bounded device reader trace image')
    frozen=out/'candidate';frozen.mkdir(mode=0o700)
    paths={0x2000:build/'loader/bootloader/bootloader.bin',0x8000:build/'loader/partition_table/partition-table.bin',0x10000:build/'nihos-native.bin'}
    for address,path in list(paths.items()):
        dest=frozen/path.name;shutil.copyfile(path,dest);paths[address]=dest
    shutil.copyfile(build/'image-audit.json',frozen/'image-audit.json')
    receipt={'passed':False,'evidence':'physical Tab5 ROM reader; serial input and completed framebuffer publications','hardware_pixels_observed':False,'physical_touch_tested':False,'sd_modified':False,'backup_private':True,'installed':False,'candidate':{p.name:SHA(p.read_bytes()) for p in frozen.iterdir()},'observations':[]}
    save=lambda:(out/'result.json').write_text(json.dumps(receipt,indent=2)+'\n')
    save();backup_path=out/'original-flash-16MiB.bin';wrote=False
    lock=os.open('/tmp/nihos-tab5-e8f60ae2e89c-write.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    try:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        os.ftruncate(lock,0);os.write(lock,json.dumps({'pid':os.getpid(),'task':'xy-tab5-reader','worktree':str(ROOT)}).encode());os.fsync(lock)
        owners=subprocess.run(['lsof','-t',args.port,args.port.replace('/cu.','/tty.')],capture_output=True,text=True)
        if owners.returncode not in (0,1) or owners.stdout.strip():raise RuntimeError('serial port already owned')
        with capture_serial_class(serial.Serial)(args.port,115200,timeout=.1,exclusive=True) as port:
            disable_hangup(port)
            def tool(name,tail):
                with (out/(name+'.log')).open('w') as log,contextlib.redirect_stdout(log),contextlib.redirect_stderr(log):
                    device=esptool.detect_chip(port=port,baud=115200)
                    esptool.main(['--chip','esp32p4','--baud','460800','--after','hard_reset']+tail,esp=device)
                port.baudrate=115200
            with (out/'identity.log').open('w') as log,contextlib.redirect_stdout(log),contextlib.redirect_stderr(log):
                device=esptool.detect_chip(port=port,baud=115200)
                mac=':'.join(f'{b:02x}' for b in device.read_mac());chip=device.get_chip_description();flash=device.flash_id()
            receipt['device']={'mac':mac,'chip':chip,'flash_id':flash};save()
            if mac!='e8:f6:0a:e2:e8:9c' or not chip.startswith('ESP32-P4') or flash>>16!=0x18:raise RuntimeError('unexpected device; no writes allowed')
            print('Device identity matched; '+('reusing and verifying private 16 MiB backup' if args.backup_from else 'backing up all 16 MiB of Flash'),flush=True)
            if args.backup_from: shutil.copyfile(args.backup_from,backup_path)
            else: tool('backup',['read_flash','0','0x1000000',str(backup_path)])
            backup=backup_path.read_bytes()
            if len(backup)!=16*1024*1024:raise RuntimeError('short backup')
            os.chmod(backup_path,0o600)
            receipt['backup_sha256']=SHA(backup);save()
            tool('backup-verify',['verify_flash','0',str(backup_path)])
            # Erase padding belongs to this deployment as well. Preserve every
            # modified sector and verify everything else against the backup.
            expected=bytearray(backup);restore={}
            for address,path in paths.items():
                data=path.read_bytes();end=(address+len(data)+4095)&~4095
                if end>0x410000:raise RuntimeError('candidate exceeds 4 MiB factory region')
                restore_path=out/f'restore-{address:x}.bin';restore_path.write_bytes(backup[address:end]);restore[address]=restore_path
                expected[address:end]=data+b'\xff'*(end-address-len(data))
            (out/'expected-flash-16MiB.bin').write_bytes(expected)
            tail=['write_flash','--flash_mode','dio','--flash_size','16MB','--flash_freq','80m']
            for address,path in paths.items():tail += [hex(address),str(path)]
            try:
                wrote=True;receipt['write_started']=True;save()
                print('Backup verified; installing exact candidate',flush=True)
                tool('install',tail)
                receipt['installed']=True;save()
                tool('verify-candidate',['verify_flash']+[v for address,path in paths.items() for v in (hex(address),str(path))])
                tool('verify-whole-flash',['verify_flash','0',str(out/'expected-flash-16MiB.bin')])
                receipt['outside_written_sectors_preserved']=True;save()
                raw=bytearray();capture=(out/'capture.log').open('wb')
                def record(data,marker):
                    rows=re.findall(rb'(?m)^'+marker+rb' ([^\r\n]+)\r?\n',data)
                    return {k.decode():int(v,16) for k,v in re.findall(rb'(\w+)=([0-9a-f]{8})(?:\s|$)',rows[-1])} if rows else None
                def wait(label,predicate,start=0):
                    deadline=time.monotonic()+45
                    while time.monotonic()<deadline:
                        data=port.read(max(1,port.in_waiting))
                        if data:raw.extend(data);capture.write(data);capture.flush()
                        if b'NIHOS_NATIVE_FAIL' in raw or b'NIHOS_NATIVE_FAULT' in raw:raise RuntimeError('native fault during '+label)
                        state=record(raw[start:],b'NIHOS_NATIVE_XY_READER');render=record(raw[start:],b'NIHOS_NATIVE_XY_RENDER')
                        if state and render and render['failed']==0 and state['error_code']==0 and predicate(state,render):
                            row={'name':label,**state,'render':render};receipt['observations'].append(row);save();print(label,state,flush=True);return state
                    raise TimeoutError('phase timed out: '+label)
                def send(label,data,predicate):
                    start=len(raw);port.write(data);port.flush();return wait(label,predicate,start)
                raw.clear();port.reset_input_buffer();port.dtr=False;HardReset(port,uses_usb=True)()
                wait('home-boot',lambda s,r:s['screen']==1 and r['frames']>0)
                send('grass-contents',b'2',lambda s,r:s['screen']==2 and s['book']==1)
                first=send('grass-first',b'\r',lambda s,r:s['screen']==3 and s['offset']==0 and s['end']>0)
                next_page=send('grass-next',b'\x1b[C',lambda s,r:s['screen']==3 and s['offset']==first['end'] and s['end']>s['offset'])
                send('grass-previous',b'\x1b[D',lambda s,r:s['screen']==3 and s['offset']==0)
                send('settings',b's',lambda s,r:s['screen']==4)
                send('vertical',b'v',lambda s,r:s['screen']==4 and r['axis']==1)
                send('larger',b'+',lambda s,r:s['screen']==4 and r['size']==36)
                send('gothic',b'f',lambda s,r:s['screen']==4 and r['font']==1)
                send('dark',b't',lambda s,r:s['screen']==4 and r['background']==0x121418)
                send('grass-reflow',b'\r',lambda s,r:s['screen']==3 and s['offset']==0 and s['end']>0 and r['axis']==1 and r['size']==36)
                send('home-from-book',b'\x1b',lambda s,r:s['screen']==1)
                send('sicp-contents',b'3',lambda s,r:s['screen']==2 and s['book']==2)
                send('sicp-read',b'\r',lambda s,r:s['screen']==3 and s['book']==2 and s['end']>0)
                send('home-from-sicp',b'\x1b',lambda s,r:s['screen']==1)
                send('nihos-contents',b'4',lambda s,r:s['screen']==2 and s['book']==3)
                send('nihos-chapter-select',b'\x1b[B'*4,lambda s,r:s['screen']==2)
                send('nihos-read',b'\r',lambda s,r:s['screen']==3 and s['book']==3 and s['chapter']==4 and s['end']>0)
                send('home-for-document',b'\x1b',lambda s,r:s['screen']==1)
                send('document-open',b'n',lambda s,r:s['screen']==0)
                send('document-edit',b'xy note',lambda s,r:s['screen']==0 and (record(raw,b'NIHOS_NATIVE_XY_STATE') or {}).get('bytes')==7)
                send('home-keeps-document',b'\x03',lambda s,r:s['screen']==1)
                send('document-return',b'n',lambda s,r:s['screen']==0)
                state=record(raw,b'NIHOS_NATIVE_XY_STATE')
                expected_fnv=0x811c9dc5
                for byte in b'xy note':expected_fnv=((expected_fnv^byte)*0x01000193)&0xffffffff
                if state['bytes']!=7 or state['fnv']!=expected_fnv:raise RuntimeError('document not preserved across home')
                receipt['document_preserved']=True
                # Leave a clean, fresh reader ready for the user, in light Mincho vertical.
                raw.clear();port.reset_input_buffer();port.dtr=False;HardReset(port,uses_usb=True)()
                wait('final-fresh-home',lambda s,r:s['screen']==1)
                final_book=1 if args.leave_book=='grass' else 2
                send('final-'+args.leave_book+'-contents',str(final_book+1).encode(),lambda s,r:s['screen']==2 and s['book']==final_book)
                send('final-'+args.leave_book,b'\r',lambda s,r:s['screen']==3 and s['end']>0)
                send('final-settings',b's',lambda s,r:s['screen']==4)
                send('final-vertical',b'v',lambda s,r:r['axis']==1)
                send('final-book-visible',b'\r',lambda s,r:s['screen']==3 and r['axis']==1 and s['end']>0)
                receipt['boot_count']=raw.count(b'ESP-ROM:esp32p4')
                if receipt['boot_count']!=1:raise RuntimeError('unexpected reset in final boot')
                receipt['passed']=True;save();capture.close()
            except BaseException:
                if wrote:
                    print('Qualification failed; restoring modified sectors from private backup',flush=True)
                    tail=['write_flash','--flash_mode','keep','--flash_size','keep','--flash_freq','keep']
                    for address,path in restore.items():tail += [hex(address),str(path)]
                    try:
                        tool('restore',tail);tool('restore-verify',['verify_flash','0',str(backup_path)])
                        receipt['restored_original']=True;save()
                    except BaseException as error:
                        receipt['restore_error']=str(error);save()
                raise
    finally:
        os.close(lock)

if __name__=='__main__':main()
