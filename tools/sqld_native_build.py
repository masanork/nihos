"""Build the permanent freestanding sqld with a fixed PSRAM SQLite heap."""
import hashlib
import json
import os
import runpy
from pathlib import Path
import subprocess
import sys
ROOT = Path(__file__).resolve().parents[1]
DEFINES = ['SQLITE_THREADSAFE=0','SQLITE_OMIT_LOAD_EXTENSION','SQLITE_OMIT_WAL','SQLITE_OMIT_LOCALTIME','SQLITE_OMIT_AUTOINIT','SQLITE_OMIT_DESERIALIZE','SQLITE_OS_OTHER=1','SQLITE_ENABLE_MEMSYS5','SQLITE_ZERO_MALLOC=1','SQLITE_TEMP_STORE=3','SQLITE_DEFAULT_PAGE_SIZE=4096','SQLITE_ENABLE_API_ARMOR']
def build(work):
    work = Path(work).resolve();work.mkdir(parents=True, exist_ok=True)
    zig = ROOT / '.tools/zig-0.17.0/zig'
    subprocess.run(['sh', str(ROOT / 'tools/bootstrap-sqlite.sh')], check=True, stdout=subprocess.DEVNULL)
    sqlite = ROOT / 'build/sqlite/sqlite-amalgamation-3540100'
    target = ['-target','riscv32-freestanding-none','-mcpu=generic_rv32+m+a+c+zicsr+zifencei']
    profile = work / 'sqld_options.zig'
    profile.write_text('pub const sqld_provision_cid: u32 = '+str(int(os.environ.get('NIHOS_NATIVE_SQLD_PROVISION_CID','0'),0))+';\n')
    module = [*target, '-O', 'small']
    objects = []
    for name,path in [('store', 'src/storage/store_abi.zig'), ('runtime','src/platform/native/sqld_runtime.zig')]:
        out = work / ('sqld_'+name+'.o')
        command = [str(zig),'build-obj','-fllvm','-fno-strip','-fno-stack-check','-fno-stack-protector','-fno-unwind-tables',*module]
        if name == 'runtime':
            command += ['--dep','task_calls','--dep','task_control','--dep','timer_group','--dep','native_options']
        command += ['-Mroot='+str(ROOT/path)]
        if name == 'runtime':
            command += [*module,'--dep','task_control','-Mtask_calls='+str(ROOT/'src/arch/riscv32/task_calls.zig'),*module,'-Mtask_control='+str(ROOT/'src/kernel/task_control.zig'),*module,'-Mtimer_group='+str(ROOT/'src/soc/esp32p4/timer_group.zig'),*module,'-Mnative_options='+str(profile)]
        command += ['-femit-bin='+str(out)]
        subprocess.run(command, check=True);objects.append(out)
    defines = DEFINES
    headers=ROOT/'.tools/zig-0.17.0/lib/libc/include'
    flags = [str(zig),'cc',*target,'-mabi=ilp32','-Oz','-std=c11','-ffreestanding','-fno-builtin','-fno-pic','-ffunction-sections','-fdata-sections','-fno-stack-protector','-fno-unwind-tables','-fno-asynchronous-unwind-tables','-fstack-size-section','-I'+str(ROOT/'include'),'-I'+str(sqlite)]
    for folder in ['riscv32-linux-musl','generic-musl','riscv-linux-any']: flags+=['-isystem',str(headers/folder)]
    flags += ['-D'+v for v in defines]
    inputs = [sqlite/'sqlite3.c', ROOT/'src/services/sqld.c',ROOT/'src/services/sqlite_store_vfs.c',ROOT/'src/services/sqld_native_allocator.c']
    for source in inputs:
        out = work/('sqld_'+source.stem+'.o');subprocess.run([*flags,'-c',str(source),'-o',str(out)], check=True);objects.append(out)
    sources = inputs + list((ROOT/'src').rglob('*.zig')) + list((ROOT/'include').glob('*.h')) + [Path(__file__),ROOT/'tools/build-native-elf.sh',ROOT/'src/platform/native/esp32p4.ld']
    manifest={'kind':'normal-sqld','transaction_timeout_ms':30000,'flash':[0x40400000,786432],'defines':defines,'provision_cid':int(os.environ.get('NIHOS_NATIVE_SQLD_PROVISION_CID','0'),0),'cache':[0x48340000,524288],'eval_stack':[0x48230000,65536],'reservation':[0x48200000,2097152],'heap':[0x48240000,1048576],'stack':[0x483c0000,65536],'media':[2048,8192],'sources':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},'objects':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in objects}}
    functions=runpy.run_path(str(ROOT/'tools/native-sqlite-manifest.py'))['functions']
    manifest['allowed_functions']=sorted(set().union(*(set(functions(p)) for p in objects)))
    identity=hashlib.sha256(json.dumps(manifest,sort_keys=True).encode()).hexdigest();manifest['identity']=identity
    (work/'sqld-manifest.json').write_text(json.dumps(manifest,sort_keys=True,indent=2)+'\n')
    source=work/'sqld_identity.c';source.write_text('__attribute__((used,section(".sqld.identity"))) const char nih_sqld_identity[]="NIHOS_SQLD1:'+identity+'";\n')
    out=work/'sqld_identity.o';subprocess.run([*flags,'-c',str(source),'-o',str(out)],check=True);objects.append(out)
    return objects
if __name__=='__main__': print(json.dumps([str(p) for p in build(sys.argv[1])]))
