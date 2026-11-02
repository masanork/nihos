#!/usr/bin/env python3
"""Extract exact ELF32 symbol evidence for an emulator instruction probe."""
import argparse, hashlib, json, struct
from pathlib import Path

def symbol(path, name):
    data=path.read_bytes()
    if data[:7]!=b'\x7fELF\x01\x01\x01': raise ValueError('expected ELF32 little endian')
    header=struct.unpack_from('<HHIIIIIHHHHHH',data,16)
    if header[1]!=243: raise ValueError('expected RISC-V')
    shoff,stride,count=header[5],header[10],header[11]
    if stride!=40: raise ValueError('unexpected section header size')
    sections=[struct.unpack_from('<10I',data,shoff+i*stride) for i in range(count)]
    found=[]
    for section in sections:
        if section[1]!=2:continue
        if section[9]!=16 or section[6]>=len(sections):raise ValueError('bad symbol table')
        string_section=sections[section[6]];strings=data[string_section[4]:string_section[4]+string_section[5]]
        for offset in range(section[4],section[4]+section[5],section[9]):
            start,value,size,info,_,index=struct.unpack_from('<IIIBBH',data,offset)
            end=strings.find(b'\0',start)
            if end<0:raise ValueError('bad string table')
            if strings[start:end].decode('utf-8','replace')==name and index!=0:
                found.append({'address':hex(value),'bytes':size,'type':info&15})
    if len(found)!=1 or found[0]['type']!=2:raise ValueError(f'expected one defined function: {found}')
    return {'elf_sha256':hashlib.sha256(data).hexdigest(),'symbol':name,**found[0]}
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('elf',type=Path);p.add_argument('symbol');a=p.parse_args();print(json.dumps(symbol(a.elf,a.symbol),indent=2))
