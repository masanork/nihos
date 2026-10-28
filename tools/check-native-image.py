#!/usr/bin/env python3
"""Audit the native ELF/image boundary without requiring a target toolchain.

Require SRAM runtime/mutable data, bounded Flash boot code and read-only tables,
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
STACK_LOW, STACK_HIGH = 0x4FF60000, 0x4FF6E000
ROM_SYMBOLS = {"nih_rom_putc": 0x4FC00054,
               "nih_rom_get_cpu_ticks": 0x4FC00040,
               "nih_rom_set_cpu_ticks": 0x4FC00044,
               "nih_rom_set_cpu1_entry": 0x4FC000A8,
               "nih_rom_l2_line_size": 0x4FC003CC,
               "nih_rom_l2_enable": 0x4FC00504,
               "nih_rom_cache_invalidate": 0x4FC003E4,
               "nih_rom_cache_writeback": 0x4FC003F4}
FLASH_SECTIONS = {".flash.appdesc": (0x40000020, 256),
                  ".flash.boot": (0x40000120, None),
                  ".flash.rodata": (0x40010020, None)}


SQL_START, SQL_END = 0x40020000, 0x400C0000
SQL_SECTIONS = {".flash.sqltext", ".flash.sqlrodata", ".flash.sqlpad"}
GRAPH_START, GRAPH_END = 0x40020000, 0x40C00000
GRAPH_SECTIONS = {".flash.graphtext", ".flash.graphrodata", ".flash.graphfonts", ".flash.graphpad", ".flash.graphrender"}
RENDER_FUNCTIONS = {"main.graphicsReport", "native_font_exchange.sourceHash", "native_font_exchange.drawHash", "native_font_exchange.stageText", "native_surface.verify", "native_surface.prepare", "native_surface.paint", "native_surface.draw"}
RENDER_RESIDENT = {"native_surface.stage", "native_surface.verifySource", "native_surface.compose", "native_surface.contextAllowed", "native_surface.captureTimer",
                   "nih_native_dispatch", "nih_native_trap", "heap.allocTask", "heap.freeTask"}
GRAPH_RAM_LOW, GRAPH_RAM_HIGH = 0x4FF78000, 0x4FF80000
GRAPH_STACK_LOW, GRAPH_STACK_HIGH = 0x4FF6E000, 0x4FF76000

def audit_flash_section(name, kind, flags, address, size, allow_sql=False, allow_graphics=False):
    if name in GRAPH_SECTIONS:
        readonly = flags & 7 == 2 and flags & ~50 == 0
        require(allow_graphics and kind == 1 and (flags == 6 if name in (".flash.graphtext", ".flash.graphrender") else readonly), "unapproved graphics Flash section")
        if name == ".flash.graphpad":
            require(0x40010020 < address < GRAPH_START and address + size == GRAPH_START, "invalid graphics Flash padding")
        else:
            require(GRAPH_START <= address < address + size <= GRAPH_END, "invalid graphics Flash extent")
        return
    if name == ".flash.sqlpad":
        require(allow_sql and kind == 1 and flags == 2 and 0x40010020 < address < SQL_START and address + size == SQL_START,
                "invalid SQLite Flash padding")
        return
    if name in SQL_SECTIONS:
        require(allow_sql and kind == 1 and (flags == 6 if name == ".flash.sqltext" else (flags & 7 == 2 and flags & ~50 == 0)),
                "unapproved/mutable SQLite Flash section")
        require(SQL_START <= address < address + size <= SQL_END and
                (name != ".flash.sqltext" or address == SQL_START), "invalid SQLite Flash extent")
        return
    expected = FLASH_SECTIONS.get(name)
    require(expected is not None and address == expected[0], "unexpected non-SRAM section: " + name)
    # SHF_MERGE/SHF_STRINGS describe immutable constant folding, not memory
    # permissions. Small headless tables may retain these linker metadata bits.
    permissions = flags == 6 if name == ".flash.boot" else (
        flags & 7 == 2 and flags & ~50 == 0 if name == ".flash.rodata" else flags == 2)
    require(kind == 1 and permissions, "invalid Flash PROGBITS permissions")
    maximum = 65248 if name == ".flash.boot" else 65504
    require(size == expected[1] if expected[1] is not None else 0 < size <= maximum,
            "invalid Flash section size")


def audit_graphics_sram(name, kind, flags, address, size):
    require(flags == 3, "graphics SRAM must be writable non-executable")
    if name == ".graphics.stack":
        require(kind == 8 and address == GRAPH_STACK_LOW and size == 32768, "invalid graphics stack")
    else:
        require(name in (".graphics.data", ".graphics.bss") and kind == (1 if name == ".graphics.data" else 8) and
                GRAPH_RAM_LOW <= address < address + size <= GRAPH_RAM_HIGH, "invalid graphics SRAM data")


def audit_render(section, functions):
    low, data = section
    high = low + len(data)
    require(low % 4 == 0 and 0 < len(data) <= 16384, "invalid rendering Flash extent")
    selected = [(name, start, end) for name, start, end in functions if low <= start < high or start < low < end]
    require(len(selected) == len(RENDER_FUNCTIONS) and {n for n, _, _ in selected} == RENDER_FUNCTIONS,
            "unexpected/missing rendering Flash function")
    selected.sort(key=lambda item: item[1])
    require(selected[0][1] == low and all(low <= start < end <= high for _, start, end in selected) and
            0 <= high - selected[-1][2] < 16 and
            all(0 <= right[1] - left[2] < 16 for left, right in zip(selected, selected[1:])),
            "overlapping/unaccounted rendering Flash function extent")
    resident = {name: {"start": hex(start), "end": hex(end)} for name, start, end in functions if name in RENDER_RESIDENT}
    require(set(resident) == RENDER_RESIDENT and all(0x4ff00000 <= int(f["start"], 16) < int(f["end"], 16) <= 0x4ff48000 for f in resident.values()),
            "renderer guard/allocator/trap helper must remain SRAM")
    return {"start": hex(low), "end": hex(high), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
            "functions": {name: {"start": hex(start), "end": hex(end)} for name, start, end in selected},
            "resident": resident}


def audit_graphics(sections, symbols, sizes, functions, manifest, tables):
    require(manifest and manifest.get("schema") == 1 and manifest.get("allowed_functions"), "missing graphics object manifest")
    require(set(sections) == GRAPH_SECTIONS | {".graphics.data", ".graphics.bss", ".graphics.stack"}, "missing graphics sections")
    text, ro, fonts, pad = (sections[n] for n in (".flash.graphtext", ".flash.graphrodata", ".flash.graphfonts", ".flash.graphpad"))
    require(text[0] == GRAPH_START and text[0] + len(text[1]) == ro[0] and
            0 <= fonts[0] - ro[0] - len(ro[1]) < 16 and fonts[0] % 16 == 0, "noncontiguous graphics Flash layout")
    require(pad[0] == 0x40010020 + ((len(tables) + 3) & ~3) and not any(pad[1]) and
            pad[0] + len(pad[1]) == GRAPH_START, "nonzero/noncontiguous graphics padding")
    require(symbols.get("__graphics_font_stack_bottom") == GRAPH_STACK_LOW and symbols.get("__graphics_font_stack_top") == GRAPH_STACK_HIGH,
            "graphics stack symbols differ")
    require(symbols.get("__graphics_bss_start") == sections[".graphics.bss"][0] and symbols.get("__graphics_bss_end") == sections[".graphics.bss"][0] + sections[".graphics.bss"][2], "graphics BSS zeroing bounds differ")
    require(not {"malloc", "calloc", "realloc", "free", "__getreent"}.intersection(symbols), "unprefixed graphics C runtime")
    for name in ("memcpy", "memset", "memmove", "memcmp", "__udivdi3"):
        require(name not in symbols or any(low <= symbols[name] < high and 0x4ff00000 <= low < high <= 0x4ff48000 for _, low, high in functions), "kernel helper redirected to graphics Flash")
    selected = {name: {"start": hex(low), "end": hex(high)} for name, low, high in functions if GRAPH_START <= low < high <= ro[0]}
    require({"graphics_font_link_probe", "nih_gfx_study_malloc"}.issubset(selected), "missing graphics functions")
    require(GRAPH_RAM_LOW <= symbols.get("graphics_output", 0) < GRAPH_RAM_HIGH and sizes.get("graphics_output") == 844, "graphics output ABI/data placement differs")
    require(GRAPH_RAM_LOW <= symbols.get("graphics_result", 0) < GRAPH_RAM_HIGH and sizes.get("graphics_result") == 124, "graphics result ABI/data placement differs")
    render = sections[".flash.graphrender"]
    require(render[0] == (fonts[0] + len(fonts[1]) + 3) & ~3, "noncontiguous rendering Flash layout")
    render_report = audit_render(render, functions)
    require(symbols.get("__flash_render_start") == render[0] and symbols.get("__flash_render_end") == render[0] + len(render[1]) and
            symbols.get("__flash_graphics_end") == render[0] + len(render[1]), "rendering Flash symbols differ")
    inputs = []
    for item in manifest["fonts"]:
        low, high = (symbols.get("nih_graphics_" + item["family"] + suffix, 0) for suffix in ("_start", "_end"))
        require(fonts[0] <= low < high <= fonts[0] + len(fonts[1]) and high - low == item["bytes"], "font extent differs")
        require(hashlib.sha256(fonts[1][low - fonts[0]:high - fonts[0]]).hexdigest() == item["sha256"], "font bytes differ from pinned source")
        inputs.append({**item, "start": hex(low), "end": hex(high)})
    payload = tables + bytes((-len(tables)) % 4) + pad[1] + text[1] + ro[1] + bytes(fonts[0] - ro[0] - len(ro[1])) + fonts[1]
    payload += bytes(render[0] - fonts[0] - len(fonts[1])) + render[1]
    payload += bytes((-len(payload)) % 4)
    return {"render": render_report, "text_start": hex(text[0]), "text_end": hex(ro[0]), "text_bytes": len(text[1]),
            "rodata_bytes": len(ro[1]), "fonts_bytes": len(fonts[1]), "fonts": inputs,
            "functions": selected, "payload_sha256": manifest["payload_sha256"], "padding_bytes": len(pad[1]),
            "static_data_bytes": sections[".graphics.data"][2], "static_bss_bytes": sections[".graphics.bss"][2],
            "stack_bytes": 32768, "ram_reserved_bytes": 32768}, (text[0], ro[0]), payload


def audit_boot_functions(functions, start, end, low, high, sql_span=None, sql_functions=(), render_span=None):
    found = {}
    for name, address, stop in functions:
        if low <= address < high:
            require(stop <= high, "function exceeds SRAM: " + name)
            continue
        if ROM_SYMBOLS.get(name) == address:
            continue
        if sql_span is not None and sql_span[0] <= address < stop <= sql_span[1]:
            require(name in sql_functions, "non-manifest function in mapped library Flash: " + name)
            continue
        if render_span is not None and render_span[0] <= address < stop <= render_span[1]:
            require(name in RENDER_FUNCTIONS, "unapproved rendering Flash function: " + name)
            continue
        role = "probe" if name == "psram.probe" else "mapping" if re.fullmatch(r"psram_memory\.prepare__func_[0-9]+", name) else "clock" if re.fullmatch(r"cpu_boot\.run__func_[0-9]+", name) else None
        require(role is not None and start <= address < stop <= end, "unapproved Flash function: " + name)
        require(role not in found, "duplicate Flash boot role")
        found[role] = {"name": name, "start": hex(address), "end": hex(stop)}
    require(set(found) in ({"probe", "mapping"}, {"probe", "mapping", "clock"}), "missing approved Flash boot functions")
    ordered = sorted(found.values(), key=lambda entry: int(entry["start"], 16))
    require(int(ordered[0]["start"], 16) == start and int(ordered[-1]["end"], 16) == end and
            all(0 <= int(right["start"],16)-int(left["end"],16) <= 16 for left,right in zip(ordered,ordered[1:])),
            "overlapping/unaccounted Flash boot extent")
    return found


def audit_app_descriptor(data):
    require(len(data) == 256 and struct.unpack_from("<I", data)[0] == 0xABCD5432,
            "invalid app descriptor")
    require(data[180] == 16, "app descriptor must select 64 KiB MMU pages")


def fnv1a(data):
    value = 2166136261
    for byte in data:
        value = ((value ^ byte) * 16777619) & 0xffffffff
    return value


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
    require(low <= symbols["__bss_end"] <= start < end == high and
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


def audit_stack_section(kind, flags, address, size):
    require(kind == 8 and flags == 3 and address == STACK_LOW and size == STACK_HIGH - STACK_LOW,
            "stacks must be the fixed writable non-executable NOBITS bank")


def audit_stack_layout(symbols, sizes, allocated):
    expected = {"__stacks_start": STACK_LOW, "__stack0_bottom": STACK_LOW,
                "__stack0_top": STACK_LOW + 8192, "__stack1_bottom": STACK_LOW + 8192,
                "__stack1_top": STACK_LOW + 16384, "__irq_stack0_bottom": STACK_LOW + 16384,
                "__irq_stack0_top": STACK_LOW + 24576, "__irq_stack1_bottom": STACK_LOW + 24576,
                "__irq_stack1_top": STACK_LOW + 32768, "__task_stacks_start": STACK_LOW + 32768,
                "__task_stacks_end": STACK_HIGH, "__stacks_end": STACK_HIGH,
                "native_tasks.stacks": STACK_LOW + 32768}
    require(all(symbols.get(name) == value for name, value in expected.items()), "stack symbols differ from fixed bank layout")
    require(sizes.get("native_tasks.stacks") == 24576, "worker stack array size differs from reservation")
    stacks = [section for section in allocated if section["name"] == ".stacks"]
    require(len(stacks) == 1 and int(stacks[0]["address"], 16) == STACK_LOW and stacks[0]["bytes"] == STACK_HIGH - STACK_LOW,
            "missing/invalid stack bank section")
    return {"start": hex(STACK_LOW), "end": hex(STACK_HIGH), "bytes": STACK_HIGH - STACK_LOW,
            "bootstrap_bytes_per_hart": 8192, "irq_bytes_per_hart": 8192,
            "worker_bytes": 4096, "workers_per_hart": 3, "worker_start": hex(STACK_LOW + 32768)}


def decode_stack_sizes(data, functions):
    """LLVM static C frames, not a recursive call-graph/whole-stack bound."""
    names = {}
    for name, address, _ in functions:
        names.setdefault(address, []).append(name)
    rows = []
    cursor = 0
    while cursor < len(data):
        require(cursor + 4 <= len(data), "truncated C stack address")
        address = struct.unpack_from("<I", data, cursor)[0]
        cursor += 4
        value, shift = 0, 0
        while True:
            require(cursor < len(data) and shift < 35, "truncated/overflowing C stack size")
            byte = data[cursor]
            cursor += 1
            value |= (byte & 127) << shift
            shift += 7
            if byte & 128 == 0:
                break
        require(address in names and value <= 0xffffffff, "unknown C stack function/size")
        rows.append({"address": hex(address), "functions": sorted(names[address]), "bytes": value})
    require(rows, "empty C static stack metadata")
    return {"records": len(rows), "maximum_reported_frame_bytes": max(row["bytes"] for row in rows),
            "largest_frames": sorted(rows, key=lambda row: row["bytes"], reverse=True)[:10],
            "recursive_or_Zig_call_graph_bound": False}


def audit(elf, image, mode=None, profile="device", sqlite_manifest=None):
    require(profile in SRAM_PROFILES, "invalid native memory profile")
    low, high, revision = SRAM_PROFILES[profile]
    require(high <= STACK_LOW, "stack bank overlaps primary SRAM")
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
    symbol_sizes = {}
    functions = []
    executable = []
    flash_found = set()
    flash_tables = None
    boot_code = None
    sql_sections = {}
    graph_sections = {}
    allow_sql = mode == "sqlite"
    allow_graphics = mode == "graphics"
    require(not allow_sql or (sqlite_manifest is not None and sqlite_manifest.get("schema") == 1 and
                             sqlite_manifest.get("allowed_functions")), "missing SQLite object manifest")
    for section in sections:
        name_id, section_type, flags, address, offset, size, link, _, _, stride = section
        name = string(names, name_id)
        if flags & 2 and size:  # SHF_ALLOC
            require(section_type not in (14, 15, 16) and name not in (".ctors", ".dtors") and flags & 0x400 == 0,
                    "native CRT does not support dynamic initializers or TLS")
            if name == ".heap":
                require(section_type == 8 and flags & 7 == 3, "heap must be writable NOBITS")
            in_stacks = name == ".stacks"
            if in_stacks:
                audit_stack_section(section_type, flags, address, size)
            in_sram = low <= address and address + size <= high
            in_graphics_ram = name in (".graphics.data", ".graphics.bss", ".graphics.stack")
            if in_graphics_ram:
                require(allow_graphics, "unapproved graphics SRAM reservation")
                audit_graphics_sram(name, section_type, flags, address, size)
                graph_sections[name] = (address, elf[offset:offset+size] if section_type == 1 else b"", size)
            if not in_sram and not in_stacks and not in_graphics_ram:
                audit_flash_section(name, section_type, flags, address, size, allow_sql, allow_graphics)
                require(name not in flash_found, "duplicate mapped Flash section")
                flash_found.add(name)
                if name in SQL_SECTIONS:
                    sql_sections[name] = (address, elf[offset:offset + size])
                if name in GRAPH_SECTIONS:
                    graph_sections[name] = (address, elf[offset:offset + size])
                if name == ".flash.appdesc":
                    audit_app_descriptor(elf[offset:offset + size])
                if name == ".flash.rodata":
                    flash_tables = elf[offset:offset + size]
                    require(len(flash_tables) == size, "truncated Flash tables")
                if name == ".flash.boot":
                    boot_code = elf[offset:offset + size]
                    require(len(boot_code) == size, "truncated Flash boot code")
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
                    functions.append((symbol, value, value + symbol_size))
                symbols[symbol] = value
                symbol_sizes[symbol] = symbol_size
    require(flash_found == set(FLASH_SECTIONS) | (SQL_SECTIONS if allow_sql else set()) | (GRAPH_SECTIONS if allow_graphics else set()), "missing mapped Flash sections")
    sql_span = None
    sql_report = None
    if allow_sql:
        pad_start, sql_pad = sql_sections[".flash.sqlpad"]
        require(pad_start == FLASH_SECTIONS[".flash.rodata"][0] + ((len(flash_tables) + 3) & ~3) and not any(sql_pad), "invalid nonzero/noncontiguous SQLite padding")
        text_start, sql_code = sql_sections[".flash.sqltext"]
        ro_start, sql_ro = sql_sections[".flash.sqlrodata"]
        text_end, ro_end = text_start + len(sql_code), ro_start + len(sql_ro)
        require(ro_start == text_end and text_end % 16 == 0 and ro_end <= SQL_END, "invalid SQLite code/rodata ordering")
        expected_symbols = {"__flash_sql_text_start": text_start, "__flash_sql_text_end": text_end,
                            "__flash_sql_rodata_start": ro_start, "__flash_sql_rodata_end": ro_end}
        require(all(symbols.get(key) == value for key, value in expected_symbols.items()), "SQLite linker symbols differ")
        sql_span = (text_start, text_end)
        sql_funcs = {name: {"start": hex(low), "end": hex(high)} for name, low, high in functions
                     if text_start <= low < high <= text_end}
        require({"nih_sqlite_session_open", "nih_sqlite_session_eval", "nih_sqlite_session_close", "sqlite3_open"}.issubset(sql_funcs),
                "missing actual SQLite/session functions")
        quotas = sqlite_manifest.get("pool_quotas")
        require(isinstance(quotas, list) and len(quotas) == 10 and all(isinstance(n, int) and 0 < n <= 65535 for n in quotas), "invalid SQLite manifest quotas")
        sql_report = {"pool_quotas": quotas, "text_start": hex(text_start), "text_end": hex(text_end), "rodata_start": hex(ro_start),
                      "rodata_end": hex(ro_end), "text_bytes": len(sql_code), "rodata_bytes": len(sql_ro),
                      "functions": sql_funcs, "object_manifest_sha256": hashlib.sha256(json.dumps(sqlite_manifest, sort_keys=True).encode()).hexdigest(),
                      "text_sha256": hashlib.sha256(sql_code).hexdigest(), "rodata_sha256": hashlib.sha256(sql_ro).hexdigest()}
        if 'littlefs' in sqlite_manifest:
            lfs = sqlite_manifest['littlefs']
            require(lfs.get('read_only') is True and lfs.get('no_malloc') is True and
                    lfs.get('revision') == '6cb4e86540eca0d9ba62500a298385c9d863c8be', 'unapproved littlefs build profile')
            require({'lfs_mount', 'lfs_unmount', 'lfs_dir_read', 'lfs_file_read', 'nih_storage_probe'}.issubset(sql_funcs), 'missing littlefs reader functions')
            require(not {'lfs_format', 'lfs_file_write', 'lfs_remove', 'lfs_mkdir', 'lfs_rename', 'lfs_file_truncate'}.intersection(symbols), 'littlefs write API linked')
            sql_report['littlefs'] = lfs
        stack_data = [elf[section[4]:section[4] + section[5]] for section in sections
                      if string(names, section[0]) == ".stack_sizes"]
        require(len(stack_data) == 1, "missing/duplicate C stack metadata")
        sql_report["static_c_stack"] = decode_stack_sizes(stack_data[0], functions)
        sql_payload = flash_tables + bytes((-len(flash_tables)) % 4) + sql_pad + sql_code + sql_ro
        sql_payload += bytes((-len(sql_payload)) % 4)
        sql_report["padding_bytes"] = len(sql_pad)
    boot_start = FLASH_SECTIONS[".flash.boot"][0]
    boot_end = boot_start + len(boot_code)
    require(symbols.get("__flash_boot_start") == boot_start and symbols.get("__flash_boot_end") == boot_end,
            "Flash boot symbols differ from section")
    graph_report, graph_payload = None, None
    if allow_graphics:
        graph_report, sql_span, graph_payload = audit_graphics(graph_sections, symbols, symbol_sizes, functions, sqlite_manifest, flash_tables)
    boot_functions = audit_boot_functions(functions, boot_start, boot_end, low, high, sql_span, sqlite_manifest["allowed_functions"] if allow_sql or allow_graphics else (),
                                          (int(graph_report["render"]["start"], 16), int(graph_report["render"]["end"], 16)) if allow_graphics else None)
    flash_start = FLASH_SECTIONS[".flash.rodata"][0]
    require(symbols.get("__flash_records_start") == flash_start and
            symbols.get("__flash_records_end") == flash_start + len(flash_tables),
            "Flash record symbols differ from section")
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
    stacks = audit_stack_layout(symbols, symbol_sizes, allocated)
    heap = audit_heap_layout(symbols, allocated, low, high)
    report = {"schema": 1, "backend": "native-sram", "rtos_linked": False,
              "fp_assembly_linked": fp_linked, "riscv_flags": hex(header[6]), "fp_instructions": fp_counts,
              "entry": hex(entry), "elf_sha256": hashlib.sha256(elf).hexdigest(),
              "memory": {"profile": profile, "origin": hex(low), "end": hex(high), "bytes": high - low,
                         "total_bytes": high - low + stacks["bytes"],
                         "regions": [{"name": "resident", "origin": hex(low), "end": hex(high), "bytes": high - low},
                                     {"name": "stacks", "origin": hex(STACK_LOW), "end": hex(STACK_HIGH), "bytes": stacks["bytes"]}]},
              "sram_reserved_bytes": symbols["__heap_start"] - low + stacks["bytes"],
              "primary_static_bytes": symbols["__heap_start"] - low, "stacks": stacks, "heap": heap,
              "flash_boot": {"start": hex(boot_start), "end": hex(boot_end), "bytes": len(boot_code),
                             "sha256": hashlib.sha256(boot_code).hexdigest(), "functions": boot_functions},
              "flash_records": {"start": hex(flash_start), "end": hex(flash_start + len(flash_tables)),
                                "bytes": len(flash_tables), "fnv1a": fnv1a(flash_tables),
                                "executable": False, "writable": False},
              "rom_symbols": {name: hex(value) for name, value in ROM_SYMBOLS.items()}, "sections": allocated}
    if allow_sql:
        require(not {"malloc", "calloc", "realloc", "free", "localtime", "gmtime", "strftime"}.intersection(symbols),
                "unexpected libc heap/time fallback in native SQLite image")
        report["sqlite"] = sql_report
    if allow_graphics:
        report["graphics"] = graph_report
        report["memory"]["regions"] += [{"name": "graphics-stack", "origin": hex(GRAPH_STACK_LOW), "end": hex(GRAPH_STACK_HIGH), "bytes": 32768},
                                         {"name": "graphics-data", "origin": hex(GRAPH_RAM_LOW), "end": hex(GRAPH_RAM_HIGH), "bytes": 32768}]
        report["memory"]["total_bytes"] += 65536
        report["graphics"]["static_occupied_span_bytes"] = symbols["__graphics_bss_end"] - GRAPH_RAM_LOW
        report["sram_reserved_bytes"] += 65536
    if image is None:
        return report
    require(image[0] == 0xE9 and struct.unpack_from("<I", image, 4)[0] == entry,
            "image entry differs from ELF")
    position = 24
    image_segments = []
    mapped = []
    first_length = 256 + ((len(boot_code) + 3) & ~3)
    for index in range(image[1]):
        address, length = struct.unpack_from("<II", image, position)
        position += 8
        data = image[position:position + length]
        require(len(data) == length, "truncated image segment")
        if index == 0:
            require(address == FLASH_SECTIONS[".flash.appdesc"][0] and length == first_length,
                    "invalid first descriptor/boot-code segment")
            audit_app_descriptor(data[:256])
            require(data[144:176] == hashlib.sha256(elf).digest(), "ELF digest mismatch")
            require(data[256:256 + len(boot_code)] == boot_code, "Flash boot bytes differ from ELF")
            report["flash_boot"]["image_offset"] = position + 256
        if address:
            mapped_length = len(graph_payload) if allow_graphics else len(sql_payload) if allow_sql else (len(flash_tables) + 3) & ~3
            require((low <= address and address + length <= high) or
                    (allow_graphics and address == GRAPH_RAM_LOW and length == (graph_sections[".graphics.data"][2] + 3) & ~3) or
                    (address == FLASH_SECTIONS[".flash.appdesc"][0] and length == first_length) or
                    (address == flash_start and length == mapped_length), "unexpected image load range")
            if allow_graphics and address == GRAPH_RAM_LOW:
                require(data[:graph_sections[".graphics.data"][2]] == graph_sections[".graphics.data"][1] and
                        not any(data[graph_sections[".graphics.data"][2]:]), "graphics SRAM initializer differs from ELF")
            if address in (FLASH_SECTIONS[".flash.appdesc"][0], flash_start):
                require(address % 65536 == position % 65536, "Flash image/MMU offset mismatch")
                mapped.append(address)
            if address == flash_start:
                require(data[:len(flash_tables)] == flash_tables, "mapped Flash bytes differ from ELF")
                if allow_sql:
                    require(data == sql_payload, "merged records/SQLite image bytes differ from ELF")
                    report["sqlite"]["image_offset"] = position + SQL_START - flash_start
                if allow_graphics:
                    require(data == graph_payload, "merged records/graphics image bytes differ from ELF")
                    report["graphics"]["image_offset"] = position + GRAPH_START - flash_start
                report["flash_records"]["image_offset"] = position
            image_segments.append({"address": hex(address), "bytes": length})
        position += length
    require(mapped == [FLASH_SECTIONS[".flash.appdesc"][0], flash_start], "stock loader requires exactly two mapped image sections")
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
    regions = report["memory"].get("regions", [{"name": "resident", "origin": hex(low), "end": hex(high)}])
    allocated = []
    for _, _, flags, address, _, size, *_ in sections:
        if not flags & 2 or not size:
            continue
        for region in regions:
            require(address + size <= int(region["origin"], 16) or address >= int(region["end"], 16),
                    "native SRAM overlaps live loader in " + region["name"])
        allocated.append({"address": hex(address), "bytes": size})
    higher = [int(section["address"], 16) for section in allocated
              if high <= int(section["address"], 16) < 0x50000000]
    require(bool(higher), "missing live loader SRAM allocations")
    gaps = []
    for region in regions:
        before = [int(section["address"], 16) + section["bytes"] for section in allocated
                  if int(section["address"], 16) + section["bytes"] <= int(region["origin"], 16)]
        after = [int(section["address"], 16) for section in allocated if int(section["address"], 16) >= int(region["end"], 16)]
        gaps.append({"name": region["name"], "gap_below": int(region["origin"], 16) - max(before) if before else None,
                     "gap_above": min(after) - int(region["end"], 16) if after else None})
    return {"elf_sha256": hashlib.sha256(elf).hexdigest(), "allocated": allocated,
            "nearest_higher_address": hex(min(higher)), "gap_bytes": min(higher) - high, "regions_checked": gaps}


def audit_loader_config(text, profile, report=None):
    values = dict(re.findall(r"^#define CONFIG_(CACHE_L2_CACHE_SIZE|CACHE_L2_CACHE_LINE_SIZE|ESP32P4_SELECTS_REV_LESS_V3) (\S+)$", text, re.M))
    require(int(values.get("CACHE_L2_CACHE_SIZE", "0"), 0) == 0x20000 and
            int(values.get("CACHE_L2_CACHE_LINE_SIZE", "0"), 0) == 64,
            "loader cache geometry differs from native layout")
    require(bool(int(values.get("ESP32P4_SELECTS_REV_LESS_V3", "0"), 0)) == (profile == "device"),
            "loader silicon selection differs from native layout")
    # Pinned v5.4.4 application memory.ld.in: early silicon's high RW
    # window ends below the cache; rev3 excludes its low cache prefix.
    supported_low = 0x4ff40000 if profile == "device" else 0x4ff00000 + 0x20000
    supported_high = 0x4ffc0000 - 0x20000 if profile == "device" else 0x4ffaefc0
    require(supported_low <= STACK_LOW < STACK_HIGH <= supported_high, "stack bank outside source-supported SRAM")
    if report is not None and "graphics" in report:
        for start, end in [(GRAPH_STACK_LOW, GRAPH_STACK_HIGH), (GRAPH_RAM_LOW, GRAPH_RAM_HIGH)]:
            require(supported_low <= start < end <= supported_high, "graphics reservation outside source-supported SRAM")
    return {"l2_bytes": 0x20000, "line_bytes": 64, "profile": profile,
            "stack_source_window": {"origin": hex(supported_low), "end": hex(supported_high)},
            "config_sha256": hashlib.sha256(text.encode()).hexdigest()}


def main():
    if len(sys.argv) not in (4, 5, 6, 7, 8, 9):
        raise SystemExit("usage: check-native-image.py ELF BIN|--elf-only REPORT.json [MODE [PROFILE [LOADER.elf [CONFIG.h [SQLITE-MANIFEST.json]]]]]")
    try:
        image = None if sys.argv[2] == "--elf-only" else Path(sys.argv[2]).read_bytes()
        report = audit(Path(sys.argv[1]).read_bytes(), image, sys.argv[4] if len(sys.argv) >= 5 else None,
                       sys.argv[5] if len(sys.argv) >= 6 else "device",
                       json.loads(Path(sys.argv[8]).read_text()) if len(sys.argv) == 9 else None)
        if len(sys.argv) >= 5:
            require(sys.argv[4] in ("integer", "floating", "compiled", "sqlite", "graphics"), "invalid FP mode")
            require(report["fp_assembly_linked"] == (sys.argv[4] in ("floating", "compiled")), "FP assembly differs from requested mode")
        if len(sys.argv) >= 7:
            report["loader"] = audit_loader(report, Path(sys.argv[6]).read_bytes())
        if len(sys.argv) >= 8:
            report["loader_config"] = audit_loader_config(Path(sys.argv[7]).read_text(), sys.argv[5], report)
    except (ValueError, IndexError, KeyError, struct.error) as error:
        raise SystemExit("Native image audit failed: " + str(error)) from error
    Path(sys.argv[3]).write_text(json.dumps(report, indent=2) + "\n")
    print("Native image audit passed: SRAM runtime, approved Flash boot code/tables, known ROM ABI, no RTOS symbols")


if __name__ == "__main__":
    main()
