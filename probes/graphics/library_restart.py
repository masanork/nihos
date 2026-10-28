#!/usr/bin/env python3
"""Real RV32 libraries in host Unicorn, not a native boot/IRQ/restart proof."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import subprocess
sys.dont_write_bytecode = True
import unicorn as uc
from unicorn import riscv_const as rv
from library_image import Image, BANK_START, BANK_BYTES

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(sys.argv[1]).resolve()
(OUT/'result.json').unlink(missing_ok=True)
IMAGE = Image((OUT/'oracle.elf').read_bytes())
FONTS = [ROOT/'build/graphics-probe/sources'/n for n in ('BIZUDGothic-Regular.ttf', 'BIZUDMincho-Regular.ttf')]
PRIOR = json.loads((ROOT/'docs/measurements/2026-10-28-native-stack-loan.json').read_text())
EXPECTED = PRIOR['native_result']['hashes']
for source, pinned in zip(FONTS, PRIOR['profiles']['emulator']['graphics']['fonts']):
    assert hashlib.sha256(source.read_bytes()).hexdigest() == pinned['sha256']
assert uc.__version__ == '2.1.4'
PEER_BYTES = 8*1024*1024-128


class Runtime:
    def __init__(self):
        self.cpu = uc.Uc(uc.UC_ARCH_RISCV, uc.UC_MODE_RISCV32)
        for address, length, perms in ((0x41000000, 2*1024*1024, uc.UC_PROT_ALL), (BANK_START, 1024*1024, 3),
                                      (0x52000000, 16*1024*1024, 3), (0x55001000, 32768, 3), (0x41f00000, 4096, 5)):
            self.cpu.mem_map(address, length, perms)
        for kind, offset, address, _, length, _, _, _ in IMAGE.programs:
            if kind == 1:self.cpu.mem_write(address, IMAGE.data[offset:offset+length])
        self.cpu.mem_protect(0x41000000, 2*1024*1024, 5)
        self.identity = IMAGE.sha256
        for address, source in zip((0x54000000, 0x54800000), FONTS):
            data=source.read_bytes(); length=(len(data)+4095)&~4095
            self.cpu.mem_map(address,length,3);self.cpu.mem_write(address,data);self.cpu.mem_protect(address,length,1)
        self.cpu.mem_write(0x510ff000,struct.pack('<7I',0x54000000,0x54800000,*[p.stat().st_size for p in FONTS],0x52000000,15596992,1))
        self.fault=None;self.forbidden=None;self.quiescent=True
        def invalid(cpu, access, address, size, value, data):
            self.fault=dict(access=access,address=address,pc=cpu.reg_read(rv.UC_RISCV_REG_PC));return False
        self.cpu.hook_add(uc.UC_HOOK_MEM_INVALID,invalid)
        def forbidden(cpu,address,size,data):
            self.forbidden=address;cpu.emu_stop()
        for name in ('_sbrk','_open','_write','_read','_close','_lseek','_exit','_kill','_getpid','__assert_func','abort','graphics_unavailable'):
            if name in IMAGE.symbols:
                address=IMAGE.symbols[name][0];self.cpu.hook_add(uc.UC_HOOK_BLOCK,forbidden,begin=address,end=address+max(1,IMAGE.symbols[name][1])-1)
        assert self.call('nih_graphics_backing_init',0x52000000,15596992)['returned']==0
        self.initial_free=self.call('nih_graphics_backing_initial_free')['returned']
        self.peer=None

    def call(self,name,*args):
        self.fault=None;self.forbidden=None;self.quiescent=False
        self.cpu.reg_write(rv.UC_RISCV_REG_SP,0x55009000)
        self.cpu.reg_write(rv.UC_RISCV_REG_RA,0x41f00000)
        self.cpu.reg_write(rv.UC_RISCV_REG_GP,IMAGE.symbols['__global_pointer$'][0])
        for i in range(8):self.cpu.reg_write(rv.UC_RISCV_REG_A0+i,args[i] if i<len(args) else 0)
        self.cpu.mem_write(0x55001000,b'\x67'*16)
        error=None
        try:self.cpu.emu_start(IMAGE.symbols[name][0],0x41f00000,timeout=120000000,count=4000000000)
        except uc.UcError as exc:error=str(exc)
        pc=self.cpu.reg_read(rv.UC_RISCV_REG_PC);self.quiescent=pc==0x41f00000 and error is None and self.forbidden is None
        return dict(returned=self.cpu.reg_read(rv.UC_RISCV_REG_A0),pc=pc,error=error,fault=self.fault,
                    forbidden=self.forbidden,returned_to_host=self.quiescent,stack_guard=bytes(self.cpu.mem_read(0x55001000,16))==b'\x67'*16)

    def backing_digest(self):
        start=IMAGE.sections['.backing.data'][3]
        s=IMAGE.sections['.backing.bss']; end=s[3]+s[5]
        return hashlib.sha256(bytes(self.cpu.mem_read(start,end-start))).hexdigest()

    def render(self):
        execution=self.call('graphics_font_link_probe',0x510ff000)
        raw=bytes(self.cpu.mem_read(IMAGE.symbols['graphics_result'][0],124));words=struct.unpack('<31I',raw)
        result=dict(execution=execution,stage=words[1],failure=words[2],runs=words[3],hashes=list(words[4:20]),raw_peak=words[21],retained=words[22],unavailable_calls=words[24],runtime_malloc_calls=words[25],controller_bytes=words[26],record_capacity=words[27],record_peak=words[28],record_failures=words[29],allocation_failures=words[30])
        result['passed']=execution['returned_to_host'] and execution['returned']==0 and execution['stack_guard'] and result['stage']==100 and not result['failure'] and result['runs']==16 and result['hashes']==EXPECTED and result['unavailable_calls']==result['runtime_malloc_calls']==result['record_failures']==result['allocation_failures']==0 and 0<result['record_peak']<=result['record_capacity']==1024
        return result

    def retire(self):
        assert self.quiescent
        assert self.call('nih_graphics_backing_retire')['returned']==0
        assert self.call('nih_graphics_backing_parents')['returned']==0
        assert self.call('nih_graphics_backing_loan_count')['returned']==0

    def peer_allocate(self):
        self.peer=self.call('nih_graphics_backing_peer_allocate',PEER_BYTES)['returned'];assert self.peer
        self.cpu.mem_write(self.peer,b'\xa5'*PEER_BYTES)
        self.peer_hash=hashlib.sha256(bytes(self.cpu.mem_read(self.peer,PEER_BYTES))).hexdigest()

    def reopen(self):
        assert self.call('nih_graphics_backing_reopen')['returned']==0

    def restore(self):
        IMAGE.template.restore(self.cpu.mem_write,self.identity,self.quiescent)

    def peer_valid(self):
        return hashlib.sha256(bytes(self.cpu.mem_read(self.peer,PEER_BYTES))).hexdigest()==self.peer_hash


report=dict(schema=1,evidence='host-driven RV32 ISA; no native task/IRQ/hardware restart',elf_sha256=IMAGE.sha256,
            template_sha256=IMAGE.template.data_sha256,template_bytes=BANK_BYTES,stack_bytes=32768,initializers={n:IMAGE.sections[n][5] for n in ('.library.data','.library.bss','.backing.data','.backing.bss')},negative={},positive=[])
for control in ('controller_only','bss_only_after_loan'):
    r=Runtime();first=r.render();assert first['passed'],first
    r.retire();assert r.call('nih_graphics_backing_recovered')['returned']==1
    r.peer_allocate();r.reopen()
    if control=='controller_only':
        for name in ('_ZL4pool','_ZL13backing_ready','graphics_result'):
            address,data=IMAGE.initial_symbol(name);r.cpu.mem_write(address,data)
    else:
        r.cpu.mem_write(BANK_START,b'\xa5'*BANK_BYTES)
        s=IMAGE.sections['.library.bss'];r.cpu.mem_write(s[3],b'\0'*s[5])
    failed=r.render();assert not failed['passed'],control
    execution=failed['execution']
    if control=='controller_only':
        assert execution['fault'] and execution['fault']['address']==0xa5a5a5a5 and failed['stage']==1 and failed['failure']==0
    else:
        assert failed['stage']==1 and failed['failure']==1 and execution['error']
    prefix=sys.argv[2].removesuffix('g++')
    failed['fault_function']=subprocess.check_output([prefix+'addr2line','-C','-f','-e',str(OUT/'oracle.elf'),hex(execution['pc'])],text=True).strip()
    assert r.peer_valid()

    report['negative'][control]=dict(first=first,second=failed,peer_preserved=r.peer_valid())
    (OUT/(control+'.json')).write_text(json.dumps(report['negative'][control],indent=2)+'\n')
    print(control,failed,flush=True)

r=Runtime()
blocked=r.call('abort')
assert blocked['forbidden']==IMAGE.symbols['abort'][0] and not blocked['returned_to_host']
report['forbidden_runtime_control']=blocked
r=Runtime()
for epoch in range(3):
    if epoch:
        r.reopen();before=r.backing_digest();r.cpu.mem_write(BANK_START,b'\x5a'*BANK_BYTES);r.restore()
        assert r.backing_digest()==before and r.peer_valid()
    result=r.render();assert result['passed'],result
    assert result['retained']==65792+(8*1024*1024 if epoch else 0)
    result['epoch']=epoch+1
    result['kernel_metadata_unchanged_by_restore']=True if epoch else None
    result['kernel_metadata_sha256_before_restore']=before if epoch else None
    report['positive'].append(result);r.retire()
    if epoch==0:r.peer_allocate()
    assert r.peer_valid()
    assert r.call('nih_graphics_backing_raw_used')['returned']==8*1024*1024
    print('positive epoch',epoch+1,'passed; live peer preserved',flush=True)
assert r.call('nih_graphics_backing_peer_release')['returned']==0
assert r.call('nih_graphics_backing_recovered')['returned']==1
assert r.call('nih_graphics_backing_raw_used')['returned']==0
report.update(status='pass',positive_lifetimes=3,restarts=2,peer_preserved_bytes=PEER_BYTES,peer_charge=8*1024*1024,initial_free=r.initial_free,final_recovered=True)
(OUT/'pristine-library.bin').write_bytes(IMAGE.template.data)
(OUT/'result.json').write_text(json.dumps(report,indent=2)+'\n')
print('RV32 library image restart controls and three lifetimes passed',flush=True)
