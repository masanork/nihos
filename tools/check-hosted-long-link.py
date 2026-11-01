#!/usr/bin/env python3
"""Audit a standalone Hosted link fixture, not a bootable/native image."""
import hashlib
import json
from pathlib import Path
import struct
import sys

ROM = {"nih_rom_cache_invalidate": 0x4FC003E4,
       "nih_rom_cache_writeback": 0x4FC003F4}
LOW, HIGH = 0x4FF00000, 0x4FF20000


def require(condition, message):
    if not condition:
        raise ValueError(message)


def audit(path):
    data = Path(path).read_bytes()
    require(data[:7] == b"\x7fELF\x01\x01\x01", "expected ELF32 little endian")
    header = struct.unpack_from("<16sHHIIIIIHHHHHH", data)
    require(header[1:3] == (2, 243), "expected RISC-V executable")
    entry, shoff, shsize, count, names_index = header[4], header[6], header[11], header[12], header[13]
    require(shsize == 40 and 0 < count and shoff + count * shsize <= len(data), "bad section table")
    sections = [struct.unpack_from("<10I", data, shoff + i * shsize) for i in range(count)]

    def contents(section):
        offset, size = section[4:6]
        require(offset + size <= len(data), "section exceeds file")
        return data[offset:offset + size]

    def string(table, offset):
        require(offset < len(table), "bad string offset")
        end = table.find(b"\0", offset)
        require(end >= 0, "unterminated string")
        return table[offset:end].decode("utf-8")

    names = contents(sections[names_index])
    allocated = []
    for section in sections:
        if section[2] & 2 and section[5]:
            name = string(names, section[0])
            require(LOW <= section[3] < section[3] + section[5] <= HIGH, "section outside SRAM: " + name)
            allocated.append((section[3], section[3] + section[5], name))
    allocated.sort()
    require(all(a[1] <= b[0] for a, b in zip(allocated, allocated[1:])), "overlapping SRAM sections")
    symbols = {}
    for section in sections:
        if section[1] != 2:
            continue
        require(section[9] == 16 and section[5] % 16 == 0, "bad symbol table")
        strings = contents(sections[section[6]])
        table = contents(section)
        for offset in range(0, len(table), 16):
            name_index, value, size, info, other, index = struct.unpack_from("<IIIBBH", table, offset)
            if not name_index:
                continue
            name = string(strings, name_index)
            if info & 15 == 4:  # STT_FILE is compiler metadata, not a call.
                continue
            if name == "$d" and info == 0 and value == size == 0 and index == 0xFFF1:
                continue  # Local RISC-V debug mapping marker.
            require(index != 0, "unresolved symbol: " + name)
            if index == 0xFFF1:
                require(name in ROM and value == ROM[name], "unexpected absolute symbol: " + name)
            symbols[name] = (value, size, index)
    for name, address in ROM.items():
        require(name in symbols and symbols[name][0] == address, "missing/wrong ROM ABI: " + name)
    for name in ("nih_hosted_long_send_compile_probe", "nih_hosted_long_dma_prepare_probe", "nih_hosted_long_dma_finish_probe"):
        require(name in symbols and symbols[name][1] > 0 and LOW <= symbols[name][0] < HIGH, "missing code: " + name)
    require(entry == symbols["nih_hosted_long_send_compile_probe"][0], "wrong entry")
    address, size, index = symbols["nih_hosted_long_dma_layout"]
    section = sections[index]
    require(size == 16 and section[1] == 1, "bad DMA manifest")
    offset = address - section[3]
    require(0 <= offset <= section[5] - 16, "manifest outside section")
    start, length, descriptor, descriptor_bytes = struct.unpack_from("<4I", contents(section), offset)
    require(length == 1536 and descriptor_bytes == 64, "wrong DMA sizes")
    require(start % 64 == descriptor % 64 == 0 and start + length <= descriptor, "unaligned/overlapping DMA storage")
    dma_sections = [s for s in sections if string(names, s[0]) == ".hosted_dma"]
    require(len(dma_sections) == 1, "missing DMA section")
    dma = dma_sections[0]
    require(dma[2] == 3 and dma[8] >= 64 and dma[3] <= start and
            descriptor + descriptor_bytes <= dma[3] + dma[5], "DMA storage not in owned writable section")
    return {"elf_sha256": hashlib.sha256(data).hexdigest(), "qualification": "link-only; never boot",
            "sram_allocated_bytes": sum(end - start for start, end, _ in allocated),
            "data": {"address": hex(start), "bytes": length},
            "descriptor": {"address": hex(descriptor), "bytes": descriptor_bytes},
            "rom": {name: hex(address) for name, address in ROM.items()}}


if __name__ == "__main__":
    try:
        print(json.dumps(audit(sys.argv[1]), indent=2))
    except (ValueError, IndexError, struct.error, UnicodeError) as error:
        sys.exit("Hosted link audit failed: " + str(error))
