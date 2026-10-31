"""Exact inputs and object-function allowlist for permanent sqld, not attestation."""
import hashlib
import json
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
SECTIONS={'.flash.sqldpad','.flash.sqldtext','.flash.sqldrodata'}
FOREGROUND={'native_tasks.startSqld','diagnostic_ui.drawDetails','main.serviceStorage','ipv6.Client.tx','dhcp.Client.packet','display_probe.run','display_runtime.start','board_devices.poll','board_devices.requestDevice','main.serviceNetwork','main.normalReady','main.bootMemory','nih_native_main','main.nih_native_main','main.serviceSqld','nih_sqld_front_pump','main.nih_sqld_front_pump'}
def digest(m):
    return hashlib.sha256(json.dumps({k:v for k,v in m.items() if k!='identity'},sort_keys=True).encode()).hexdigest()
def verify(directory,m):
    if m.get('transaction_timeout_ms')!=30000 or m.get('cache')!=[0x48340000,524288] or m.get('eval_stack')!=[0x48230000,65536] or m.get('flash')!=[0x40400000,786432] or m.get('kind')!='normal-sqld' or m.get('reservation')!=[0x48200000,2097152] or m.get('heap')!=[0x48240000,1048576] or m.get('stack')!=[0x483c0000,65536] or m.get('media')!=[2048,8192]: raise ValueError('invalid sqld native profile')
    if m.get('identity')!=digest(m): raise ValueError('sqld manifest identity differs')
    for name,h in m['sources'].items():
        if hashlib.sha256((ROOT/name).read_bytes()).hexdigest()!=h: raise ValueError('sqld source differs: '+name)
    for name,h in m['objects'].items():
        if hashlib.sha256((directory/name).read_bytes()).hexdigest()!=h: raise ValueError('sqld object differs: '+name)
    if not {'SQLITE_ENABLE_MEMSYS5','SQLITE_ZERO_MALLOC=1','SQLITE_OS_OTHER=1','SQLITE_THREADSAFE=0'}.issubset(m['defines']): raise ValueError('sqld must use fixed SQLite heap')
    return b'NIHOS_SQLD1:'+m['identity'].encode()+b'\0'
