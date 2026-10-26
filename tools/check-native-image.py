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
import re

SRAM_LOW, SRAM_HIGH = 0x4FF00000, 0x4FF28000
SRAM_PROFILES = {"device": (SRAM_LOW, SRAM_HIGH, 0),
                 "emulator": (0x4FF20000, 0x4FF48000, 1)}
ROM_SYMBOLS = {"nih_rom_putc": 0x4FC00054,
               "nih_rom_set_cpu1_entry": 0x4FC000A8,
               "nih_rom_l2_line_size": 0x4FC003CC,
               "nih_rom_l2_enable": 0x4FC00504,
               "nih_rom_cache_invalidate": 0x4FC003E4,
               "nih_rom_cache_writeback": 0x4FC003F4}
FLASH_SECTIONS = {".flash.appdesc": (0x40000020, 256),
                  ".flash.rodata": (0x40010020, 4)}


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def is_fp_instruction(word, width):
    if width == 2:
        return (word & 3) in (0, 2) and (word >> 13) in (1, 3, 5, 7)
    opcode = word & 0x7f
    return opcode in (0x07, 0x27, 0x43, 0x47, 0x4b, 0x4f, 0x53) or (
        opcode == 0x73 and ((word >> 12) & 7) != 0 and (word >> 20) in (1, 2, 3))


def audit_heap_layout(symbols, allocated, low=SRAM_LOW, high=SRAM_HIGH):
    start, end = symbols["__heap_start"], symbols["__heap_end"]
    require(low <= symbols["__irq_stack1_top"] <= start < end == high and
            start % 64 == 0 and end % 64 == 0 and end - start >= 49152,
            "invalid native heap boundary")
    heap = [section for section in allocated if section["name"] == ".heap"]
    require(len(heap) == 1 and int(heap[0]["address"], 16) == start and
            heap[0]["bytes"] == end - start, "heap section differs from symbols")
    for section in allocated:
        address = int(section["address"], 16)
        if section["name"] != ".heap" and low <= address < high:
            require(address + section["bytes"] <= start, "static section overlaps native heap")
    return {"start": hex(start), "end": hex(end), "bytes": end - start,
            "owner_count": 2, "granule_bytes": 64, "external_bytes": 0}


def audit(elf, image, mode=None, profile="device"):
    require(profile in SRAM_PROFILES, "invalid native memory profile")
    low, high, revision = SRAM_PROFILES[profile]
    require(elf[:7] == b"\x7fELF\x01\x01\x01", "expected ELF32 little endian")
    header = struct.unpack_from("<HHIIIIIHHHHHH", elf, 16)
    kind, machine, _, entry, _, shoff, _, _, _, _, shsize, shnum, shstr = header
    require(kind == 2 and machine == 243, "expected executable RISC-V ELF")
    require(low <= entry < high, "entry outside profile SRAM")
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
    functions = []
    executable = []
    flash_found = set()
    for section in sections:
        name_id, section_type, flags, address, offset, size, link, _, _, stride = section
        name = string(names, name_id)
        if flags & 2 and size:  # SHF_ALLOC
            if name == ".heap":
                require(section_type == 8 and flags & 7 == 3, "heap must be writable NOBITS")
            in_sram = low <= address and address + size <= high
            if not in_sram:
                require(FLASH_SECTIONS.get(name) == (address, size),
                        "unexpected non-SRAM section: " + name)
                require(flags & (1 | 4) == 0, "writable/executable flash metadata")
                flash_found.add(name)
            allocated.append({"name": name, "address": hex(address), "bytes": size})
            if flags & 4:
                executable.append((name, address, elf[offset:offset + size]))
        if section_type == 2:  # SHT_SYMTAB
            require(stride == 16 and link < shnum, "invalid symbol table")
            table = sections[link]
            symnames = elf[table[4]:table[4] + table[5]]
            for pos in range(offset, offset + size, stride):
                name_id, value, symbol_size, info, _, index = struct.unpack_from("<IIIBBH", elf, pos)
                if not name_id:
                    continue
                symbol = string(symnames, name_id)
                require(index != 0, "unresolved symbol: " + symbol)
                require(not symbol.startswith(("xTask", "vTask", "pxCurrentTCB", "call_start_cpu")),
                        "hosted runtime symbol: " + symbol)
                if info & 15 == 2:  # STT_FUNC
                    require(low <= value < high or ROM_SYMBOLS.get(symbol) == value,
                            "function outside SRAM: " + symbol)
                    functions.append((symbol, value, value + symbol_size))
                symbols[symbol] = value
    require(flash_found == set(FLASH_SECTIONS), "missing compatibility metadata")
    require(symbols.get("nih_native_start") == entry, "wrong native entry")
    require(symbols.get("__native_profile") == revision, "ELF profile differs from requested layout")
    for name, address in ROM_SYMBOLS.items():
        require(symbols.get(name) == address, "wrong ROM ABI: " + name)
    fp_linked = "nih_riscv_fpu_save" in symbols
    if fp_linked:
        required = ["nih_riscv_fpu_restore", "nih_riscv_fpu_snapshot"]
        if mode != "compiled":
            required += ["nih_riscv_fpu_task_check", "nih_riscv_fpu_task_probe"]
        require(all(name in symbols for name in required), "partial native FP support")
    require("nih_riscv_fpu_probe_loop" not in symbols and
            "nih_riscv_preemption_budget_expired" not in symbols, "hosted test watchdog linked")
    expected_abi = 2 if mode == "compiled" else 0
    require(header[6] & 0xE == expected_abi, "native FP ABI differs from requested mode")
    fp_counts = {"app": 0, "c": 0, "zig": 0, "transfer_helpers": 0}
    helpers = {"nih_riscv_fpu_save", "nih_riscv_fpu_restore", "nih_riscv_fpu_snapshot",
               "nih_riscv_fpu_task_check", "nih_riscv_fpu_task_probe"}
    for name, address, data in executable:
        position = 0
        while position + 2 <= len(data):
            half = struct.unpack_from("<H", data, position)[0]
            width = 2 if half & 3 != 3 else 4
            require(position + width <= len(data), "truncated executable instruction")
            word = half if width == 2 else struct.unpack_from("<I", data, position)[0]
            if is_fp_instruction(word, width):
                pc = address + position
                owners = [symbol for symbol, low, high in functions if low <= pc < high]
                if any(owner in helpers for owner in owners):
                    fp_counts["transfer_helpers"] += 1
                else:
                    require(mode == "compiled" and name == ".fp_app", "FP instruction outside approved task/helper code")
                    fp_counts["app"] += 1
                    fp_counts["c" if any(owner.startswith("nih_fp_c_") for owner in owners) else "zig"] += 1
            position += width
    if mode == "compiled":
        require(fp_linked and fp_counts["c"] > 0 and fp_counts["zig"] > 0, "missing compiled C/Zig FP instructions")
    require(symbols["__stack0_top"] <= symbols["__stack1_bottom"] and
            symbols["__stack1_top"] <= symbols["__irq_stack0_bottom"] and
            symbols["__irq_stack0_top"] <= symbols["__irq_stack1_bottom"] and
            symbols["__irq_stack1_top"] <= high, "stack layout overflow")
    heap = audit_heap_layout(symbols, allocated, low, high)
    report = {"schema": 1, "backend": "native-sram", "rtos_linked": False,
              "fp_assembly_linked": fp_linked, "riscv_flags": hex(header[6]), "fp_instructions": fp_counts,
              "entry": hex(entry), "elf_sha256": hashlib.sha256(elf).hexdigest(),
              "memory": {"profile": profile, "origin": hex(low), "end": hex(high), "bytes": high - low},
              "sram_reserved_bytes": symbols["__heap_start"] - low, "heap": heap,
              "rom_symbols": {name: hex(value) for name, value in ROM_SYMBOLS.items()}, "sections": allocated}
    if image is None:
        return report
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
            require((low <= address and address + length <= high) or
                    (address, length) in FLASH_SECTIONS.values(), "unexpected image load range")
            image_segments.append({"address": hex(address), "bytes": length})
        position += length
    # ESP image checksum sits at the end of the next 16-byte block.
    checksum_end = (position + 16) & ~15
    require(image[23] == 1 and len(image) == checksum_end + 32, "missing image SHA256")
    require(hashlib.sha256(image[:checksum_end]).digest() == image[checksum_end:],
            "image SHA256 mismatch")
    report.update(image_sha256=hashlib.sha256(image).hexdigest(), image_bytes=len(image), image_segments=image_segments)
    return report


def audit_loader(report, elf):
    """Check the actual pinned loader, including allocated NOBITS data."""
    require(elf[:7] == b"\x7fELF\x01\x01\x01", "expected ELF32 loader")
    header = struct.unpack_from("<HHIIIIIHHHHHH", elf, 16)
    require(header[1] == 243 and header[10] == 40, "unexpected loader ELF")
    sections = [struct.unpack_from("<10I", elf, header[5] + index * 40) for index in range(header[11])]
    low, high = int(report["memory"]["origin"], 16), int(report["memory"]["end"], 16)
    allocated = []
    for _, _, flags, address, _, size, *_ in sections:
        if not flags & 2 or not size:
            continue
        require(address + size <= low or address >= high, "native SRAM overlaps live loader")
        allocated.append({"address": hex(address), "bytes": size})
    higher = [int(section["address"], 16) for section in allocated
              if high <= int(section["address"], 16) < 0x50000000]
    require(bool(higher), "missing live loader SRAM allocations")
    return {"elf_sha256": hashlib.sha256(elf).hexdigest(), "allocated": allocated,
            "nearest_higher_address": hex(min(higher)), "gap_bytes": min(higher) - high}


def audit_loader_config(text, profile):
    values = dict(re.findall(r"^#define CONFIG_(CACHE_L2_CACHE_SIZE|CACHE_L2_CACHE_LINE_SIZE|ESP32P4_SELECTS_REV_LESS_V3) (\S+)$", text, re.M))
    require(int(values.get("CACHE_L2_CACHE_SIZE", "0"), 0) == 0x20000 and
            int(values.get("CACHE_L2_CACHE_LINE_SIZE", "0"), 0) == 64,
            "loader cache geometry differs from native layout")
    require(bool(int(values.get("ESP32P4_SELECTS_REV_LESS_V3", "0"), 0)) == (profile == "device"),
            "loader silicon selection differs from native layout")
    return {"l2_bytes": 0x20000, "line_bytes": 64, "profile": profile,
            "config_sha256": hashlib.sha256(text.encode()).hexdigest()}


def main():
    if len(sys.argv) not in (4, 5, 6, 7, 8):
        raise SystemExit("usage: check-native-image.py ELF BIN|--elf-only REPORT.json [MODE [PROFILE [LOADER.elf [CONFIG.h]]]]")
    try:
        image = None if sys.argv[2] == "--elf-only" else Path(sys.argv[2]).read_bytes()
        report = audit(Path(sys.argv[1]).read_bytes(), image, sys.argv[4] if len(sys.argv) >= 5 else None,
                       sys.argv[5] if len(sys.argv) >= 6 else "device")
        if len(sys.argv) >= 5:
            require(sys.argv[4] in ("integer", "floating", "compiled"), "invalid FP mode")
            require(report["fp_assembly_linked"] == (sys.argv[4] != "integer"), "FP assembly differs from requested mode")
        if len(sys.argv) >= 7:
            report["loader"] = audit_loader(report, Path(sys.argv[6]).read_bytes())
        if len(sys.argv) == 8:
            report["loader_config"] = audit_loader_config(Path(sys.argv[7]).read_text(), sys.argv[5])
    except (ValueError, IndexError, KeyError, struct.error) as error:
        raise SystemExit("Native image audit failed: " + str(error)) from error
    Path(sys.argv[3]).write_text(json.dumps(report, indent=2) + "\n")
    print("Native image audit passed: SRAM only, known ROM ABI, no RTOS symbols")


if __name__ == "__main__":
    main()
