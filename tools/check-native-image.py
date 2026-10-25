#!/usr/bin/env python3
"""Audit the native ELF/image boundary without requiring a target toolchain.

Require SRAM code/data, just two read-only flash compatibility sections,
known ROM calls, no unresolved symbols, and a source-bound image descriptor.
This is a structural check, not a proof of memory safety or isolation.
"""
import hashlib
import json
from pathlib import Path
import struct
import sys

SRAM_LOW, SRAM_HIGH = 0x4FF00000, 0x4FF20000
ROM_SYMBOLS = {"nih_rom_putc": 0x4FC00054,
               "nih_rom_set_cpu1_entry": 0x4FC000A8}
FLASH_SECTIONS = {".flash.appdesc": (0x40000020, 256),
                  ".flash.rodata": (0x40010020, 4)}


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def audit(elf, image):
    require(elf[:7] == b"\x7fELF\x01\x01\x01", "expected ELF32 little endian")
    header = struct.unpack_from("<HHIIIIIHHHHHH", elf, 16)
    kind, machine, _, entry, _, shoff, _, _, _, _, shsize, shnum, shstr = header
    require(kind == 2 and machine == 243, "expected executable RISC-V ELF")
    require(SRAM_LOW <= entry < SRAM_HIGH, "entry outside internal SRAM")
    require(shsize == 40 and shstr < shnum, "invalid section table")
    sections = [struct.unpack_from("<10I", elf, shoff + i * shsize)
                for i in range(shnum)]
    strings = sections[shstr]
    names = elf[strings[4]:strings[4] + strings[5]]

    def string(table, offset):
        require(offset < len(table), "invalid string offset")
        end = table.index(0, offset)
        return table[offset:end].decode("ascii")

    allocated = []
    symbols = {}
    flash_found = set()
    for section in sections:
        name_id, section_type, flags, address, offset, size, link, _, _, stride = section
        name = string(names, name_id)
        if flags & 2 and size:  # SHF_ALLOC
            in_sram = SRAM_LOW <= address and address + size <= SRAM_HIGH
            if not in_sram:
                require(FLASH_SECTIONS.get(name) == (address, size),
                        "unexpected non-SRAM section: " + name)
                require(flags & (1 | 4) == 0, "writable/executable flash metadata")
                flash_found.add(name)
            allocated.append({"name": name, "address": hex(address), "bytes": size})
        if section_type == 2:  # SHT_SYMTAB
            require(stride == 16 and link < shnum, "invalid symbol table")
            table = sections[link]
            symnames = elf[table[4]:table[4] + table[5]]
            for pos in range(offset, offset + size, stride):
                name_id, value, _, info, _, index = struct.unpack_from("<IIIBBH", elf, pos)
                if not name_id:
                    continue
                symbol = string(symnames, name_id)
                require(index != 0, "unresolved symbol: " + symbol)
                require(not symbol.startswith(("xTask", "vTask", "pxCurrentTCB", "call_start_cpu")),
                        "hosted runtime symbol: " + symbol)
                if info & 15 == 2:  # STT_FUNC
                    require(SRAM_LOW <= value < SRAM_HIGH or ROM_SYMBOLS.get(symbol) == value,
                            "function outside SRAM: " + symbol)
                symbols[symbol] = value
    require(flash_found == set(FLASH_SECTIONS), "missing compatibility metadata")
    require(symbols.get("nih_native_start") == entry, "wrong native entry")
    for name, address in ROM_SYMBOLS.items():
        require(symbols.get(name) == address, "wrong ROM ABI: " + name)
    require(symbols["__stack0_top"] <= symbols["__stack1_bottom"] and
            symbols["__stack1_top"] <= symbols["__irq_stack0_bottom"] and
            symbols["__irq_stack0_top"] <= symbols["__irq_stack1_bottom"] and
            symbols["__irq_stack1_top"] <= SRAM_HIGH, "stack layout overflow")
    require(image[0] == 0xE9 and struct.unpack_from("<I", image, 4)[0] == entry,
            "image entry differs from ELF")
    position = 24
    image_segments = []
    for index in range(image[1]):
        address, length = struct.unpack_from("<II", image, position)
        position += 8
        data = image[position:position + length]
        require(len(data) == length, "truncated image segment")
        if index == 0:
            require((address, length) == FLASH_SECTIONS[".flash.appdesc"] and
                    struct.unpack_from("<I", data)[0] == 0xABCD5432, "invalid first app descriptor")
            require(data[144:176] == hashlib.sha256(elf).digest(), "ELF digest mismatch")
        if address:
            require((SRAM_LOW <= address and address + length <= SRAM_HIGH) or
                    (address, length) in FLASH_SECTIONS.values(), "unexpected image load range")
            image_segments.append({"address": hex(address), "bytes": length})
        position += length
    # ESP image checksum sits at the end of the next 16-byte block.
    checksum_end = (position + 16) & ~15
    require(image[23] == 1 and len(image) == checksum_end + 32, "missing image SHA256")
    require(hashlib.sha256(image[:checksum_end]).digest() == image[checksum_end:],
            "image SHA256 mismatch")
    return {"schema": 1, "backend": "native-sram", "rtos_linked": False,
            "entry": hex(entry), "elf_sha256": hashlib.sha256(elf).hexdigest(),
            "image_sha256": hashlib.sha256(image).hexdigest(), "image_bytes": len(image),
            "sram_reserved_bytes": symbols["__irq_stack1_top"] - SRAM_LOW,
            "rom_symbols": {name: hex(value) for name, value in ROM_SYMBOLS.items()},
            "sections": allocated, "image_segments": image_segments}


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: check-native-image.py ELF BIN REPORT.json")
    try:
        report = audit(Path(sys.argv[1]).read_bytes(), Path(sys.argv[2]).read_bytes())
    except (ValueError, IndexError, KeyError, struct.error) as error:
        raise SystemExit("Native image audit failed: " + str(error)) from error
    Path(sys.argv[3]).write_text(json.dumps(report, indent=2) + "\n")
    print("Native image audit passed: SRAM only, known ROM ABI, no RTOS symbols")


if __name__ == "__main__":
    main()
