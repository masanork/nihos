#!/usr/bin/env python3
"""Build RV32 layout markers and report their sizes; no device execution."""
import hashlib
import json
from pathlib import Path
import struct
import subprocess


ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'build/hosted-udp-layout'
MARKERS = ('udp_layout_sender', 'udp_layout_lease', 'udp_layout_decoder', 'udp_layout_dma')


def symbol_sizes(data):
    header = struct.unpack_from('<16sHHIIIIIHHHHHH', data)
    if header[0][:6] != b'\x7fELF\x01\x01' or header[1] != 1 or header[2] != 243:
        raise ValueError('expected little-endian RV32 relocatable ELF')
    section_offset, section_size, section_count = header[6], header[11], header[12]
    if section_size != 40 or not section_count:
        raise ValueError('invalid section table')
    sections = [struct.unpack_from('<10I', data, section_offset + i * section_size)
                for i in range(section_count)]
    result = {}
    for section in sections:
        if section[1] != 2:  # SHT_SYMTAB
            continue
        offset, size, link, stride = section[4], section[5], section[6], section[9]
        if stride != 16 or link >= len(sections) or size % stride:
            raise ValueError('invalid symbol table')
        strings = sections[link]
        table = data[strings[4]:strings[4] + strings[5]]
        for pos in range(offset, offset + size, stride):
            name_offset, _, symbol_size, _, _, index = struct.unpack_from('<IIIBBH', data, pos)
            if not name_offset or name_offset >= len(table):
                continue
            end = table.find(b'\0', name_offset)
            if end < 0:
                raise ValueError('unterminated symbol name')
            name = table[name_offset:end].decode('ascii')
            if name in MARKERS:
                if name in result or not index or not symbol_size:
                    raise ValueError('missing or duplicate layout marker')
                result[name] = symbol_size
    if set(result) != set(MARKERS):
        raise ValueError('layout markers not found')
    return result


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    zig = subprocess.check_output(['sh', str(ROOT / 'tools/bootstrap-zig.sh')], text=True).strip()
    obj, asm = OUT / 'layout.o', OUT / 'layout.s'
    args = [zig, 'build-obj', '-target', 'riscv32-freestanding-none',
            '-mcpu=generic_rv32+m+a+c+zicsr+zifencei', '-O', 'ReleaseSafe',
            str(ROOT / 'src/net/hosted_udp_layout_probe.zig'),
            '-femit-bin=' + str(obj), '-femit-asm=' + str(asm)]
    subprocess.run(args, cwd=ROOT, check=True)
    sizes = symbol_sizes(obj.read_bytes())
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    dirty = bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True).strip())
    report = {'source_head': head, 'source_dirty': dirty, 'target': 'riscv32-freestanding-none',
              'optimization': 'ReleaseSafe', 'sizes_bytes': sizes,
              'object_sha256': hashlib.sha256(obj.read_bytes()).hexdigest(),
              'scope': 'type layout and compile-only assembly; not a linked image or stack bound'}
    (OUT / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
