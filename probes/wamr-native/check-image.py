#!/usr/bin/env python3
"""Narrow structural audit for the experimental WAMR native ELF."""
import hashlib, json, struct, sys
from pathlib import Path

session = len(sys.argv) == 7 and sys.argv[6] == "--session"
if len(sys.argv) != 6 and not session: raise SystemExit("expected five paths and optional --session")
elf_path, wasm_path, package_path, update_path, report_path = map(Path, sys.argv[1:6])
elf, wasm, package, update = (elf_path.read_bytes(), wasm_path.read_bytes(),
                              package_path.read_bytes(), update_path.read_bytes())
if elf[:7] != b"\x7fELF\x01\x01\x01": raise SystemExit("expected ELF32 little endian")
header=struct.unpack_from("<HHIIIIIHHHHHH",elf,16)
if header[0]!=2 or header[1]!=243 or header[10]!=40: raise SystemExit("expected RISC-V executable")
shoff,shsize,shnum,shstr=header[5],header[10],header[11],header[12]
sections=[struct.unpack_from("<10I",elf,shoff+i*shsize) for i in range(shnum)]
strings=sections[shstr]
names=elf[strings[4]:strings[4]+strings[5]]
def string(table,offset):
    end=table.index(0,offset)
    return table[offset:end].decode("ascii")
by_name={string(names,s[0]):s for s in sections}
symbols={}
for section in sections:
    if section[1]!=2: continue
    table=sections[section[6]]
    symnames=elf[table[4]:table[4]+table[5]]
    for pos in range(section[4],section[4]+section[5],section[9]):
        name,value,size,info,other,index=struct.unpack_from("<IIIBBH",elf,pos)
        if name:
            symbol=string(symnames,name)
            if index==0: raise SystemExit("undefined symbol: "+symbol)
            symbols[symbol]=(value,size,info)
required=(".flash.rodata",".flash.wasmpad",".flash.wasmtext",".flash.wasmrodata")
if any(name not in by_name for name in required): raise SystemExit("missing WAMR Flash section")
def payload(name):
    section=by_name[name]
    return elf[section[4]:section[4]+section[5]]
records,pad,text,ro=(by_name[name] for name in required)
if pad[1]!=1 or pad[2]!=2 or pad[3]!=records[3]+records[5] or pad[3]+pad[5]!=0x40020000 or any(payload(".flash.wasmpad")):
    raise SystemExit("invalid WAMR Flash padding")
if text[1]!=1 or text[2]!=6 or text[3]!=0x40020000 or text[5]==0:
    raise SystemExit("invalid WAMR executable section")
if ro[1]!=1 or ro[2]&7!=2 or ro[3]!=text[3]+text[5] or ro[3]+ro[5]>0x400c0000:
    raise SystemExit("invalid WAMR read-only section")
expected={"__flash_wasm_text_start":text[3],"__flash_wasm_text_end":text[3]+text[5],
          "__flash_wasm_rodata_start":ro[3],"__flash_wasm_rodata_end":ro[3]+ro[5]}
if any(symbols.get(name,(None,))[0]!=value for name,value in expected.items()):
    raise SystemExit("WAMR section symbols differ")
if ("_binary_app_wasm_start" in symbols or "_binary_app_wasm_end" in symbols or
    "_binary_app_test_ed25519_nihpkg_start" in symbols):
    raise SystemExit("independent raw Wasm blob remains linked")
robytes=payload(".flash.wasmrodata")
positions=[]
cursor=0
while True:
    cursor=robytes.find(package,cursor)
    if cursor<0: break
    positions.append(cursor); cursor+=1
if len(positions)!=1: raise SystemExit(f"expected package once in journal, found {len(positions)}")
journal_names=("trust_journal","package_journal","counter_fixture","root_fixture","package_update")
journals={}
for name in journal_names:
    start=symbols.get(f"__flash_{name}_start",(0,))[0]
    end=symbols.get(f"__flash_{name}_end",(0,))[0]
    if not ro[3]<=start<end<=ro[3]+ro[5]: raise SystemExit(name+" outside read-only section")
    journals[name]=(start,end)
expected_sizes={"trust_journal":1216,"package_journal":8480,"counter_fixture":8,
                "root_fixture":32,"package_update":len(update)}
if any(journals[name][1]-journals[name][0]!=size for name,size in expected_sizes.items()):
    raise SystemExit("boot journal fixture size differs")
package_start=ro[3]+positions[0]
if package_start!=journals["package_journal"][0]: raise SystemExit("package is not journal slot zero payload")
if (len(package)!=len(wasm)+144+64 or package[:8]!=b"NIHPKG01" or
        package[144:-64]!=wasm): raise SystemExit("package framing/payload differs")
if (len(update)!=len(package) or update[:8]!=b"NIHPKG01" or
        update[144:-64]!=wasm or update==package):
    raise SystemExit("update package framing/payload differs")
update_start=journals["package_update"][0]-ro[3]
if robytes[update_start:update_start+len(update)]!=update:
    raise SystemExit("update package does not match linked candidate")
entry = ("nih_wamr_session_run",) if session else ("nih_wamr_run", "nih_package_ed25519_admit")
for name in entry + ("wasm_runtime_load","wasm_runtime_call_wasm","nih_package_boot_recover",
             "nih_app_probe_attach","nih_app_probe_detach","nih_app_fill_rect","nih_app_text"):
    address=symbols.get(name,(0,))[0]
    if not text[3]<=address<text[3]+text[5]: raise SystemExit("WAMR function outside Flash: "+name)
report={"schema":1,"evidence":"emulator-fixture","elf_sha256":hashlib.sha256(elf).hexdigest(),
        "execution":"common-session-rpc" if session else "monolithic-fixture",
        "load_source":"boot-journal","raw_wasm_symbols":0,
        "wasm_sha256":hashlib.sha256(wasm).hexdigest(),"wasm_bytes":len(wasm),
        "package_sha256":hashlib.sha256(package).hexdigest(),"package_bytes":len(package),
        "update_package_sha256":hashlib.sha256(update).hexdigest(),
        "update_package_bytes":len(update),
        "trust_journal_bytes":expected_sizes["trust_journal"],
        "package_journal_bytes":expected_sizes["package_journal"],
        "counter_fixture_bytes":expected_sizes["counter_fixture"],
        "root_fixture_bytes":expected_sizes["root_fixture"],
        "text_start":hex(text[3]),"text_bytes":text[5],"rodata_start":hex(ro[3]),
        "rodata_bytes":ro[5],"padding_bytes":pad[5],"undefined_symbols":0}
report_path.write_text(json.dumps(report,indent=2,sort_keys=True)+"\n")
print("WAMR native ELF structural audit: ok")
