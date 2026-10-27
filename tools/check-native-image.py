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
PHOTO_SECTIONS = {".flash.photo", ".flash.photo.rodata"}
UI_SECTIONS = {".flash.uipad", ".flash.ui"}
UI_POOLS = {".keypad.low": (0x4ff40000, 128 * 1024), ".keypad.high": (0x4ff70000, 188 * 1024)}

def audit_ui_pool(name, kind, flags, address, size, allowed):
    require(allowed and kind == 8 and flags == 3 and (address, size) == UI_POOLS.get(name), 'invalid keypad SRAM pool')


def audit_ui_assets(start, data, symbols, manifest):
    for role in (('font',) if manifest.get('ui_mode') == 'runtime' else ('plan', 'atlas')):
        first = symbols.get('__keypad_' + role + '_start', 0)
        last = symbols.get('__keypad_' + role + '_end', 0)
        require(start <= first < last <= start + len(data) and first % 64 == 0, 'invalid keypad asset extent')
        raw = data[first - start:last - start]
        require(len(raw) == manifest[role + '_bytes'] and hashlib.sha256(raw).hexdigest() == manifest[role + '_sha256'], 'keypad asset differs from manifest')


def audit_flash_section(name, kind, flags, address, size, allow_sql=False, allow_ui=False, allow_photo=False):
    if name in PHOTO_SECTIONS:
        require(allow_photo and kind == 1 and (flags == 6 if name == '.flash.photo' else flags & 7 == 2 and flags & ~50 == 0) and SQL_START <= address < address + size <= SQL_END, 'invalid photo codec Flash extent/permissions')
        return
    if name == '.flash.card':
        require(allow_ui and kind == 1 and flags == 6 and 0x40000120 < address < address + size <= 0x40010000, 'invalid card foreground Flash code')
        return
    if name in UI_SECTIONS:
        require(allow_ui and kind == 1 and flags & 7 == 2 and flags & ~50 == 0, 'unapproved/mutable/executable keypad Flash section')
        if name == '.flash.uipad':
            require(0x40010020 < address < SQL_START and address + size == SQL_START, 'invalid keypad Flash padding')
        else:
            require(address == SQL_START and 0 < size <= SQL_END - SQL_START, 'invalid keypad read-only extent')
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
    require(kind == 1 and flags == (6 if name == ".flash.boot" else 2),
            "invalid Flash PROGBITS permissions")
    maximum = 65248 if name == ".flash.boot" else 65504
    require(size == expected[1] if expected[1] is not None else 0 < size <= maximum,
            "invalid Flash section size")


def audit_boot_functions(functions, start, end, low, high, sql_span=None, sql_functions=(), card_span=None, card_functions=(), photo_span=None, photo_functions=(), automatic_cards=False):
    found = {}
    for name, address, stop in functions:
        if low <= address < high:
            require(stop <= high, "function exceeds SRAM: " + name)
            continue
        if ROM_SYMBOLS.get(name) == address:
            continue
        if sql_span is not None and sql_span[0] <= address < stop <= sql_span[1]:
            require(name in sql_functions, "non-manifest function in SQLite Flash: " + name)
            continue
        if card_span is not None and card_span[0] <= address < stop <= card_span[1]:
            require(any(name == prefix or re.fullmatch(re.escape(prefix) + r'__func_[0-9]+', name) for prefix in card_functions), 'unapproved card foreground function: ' + name)
            continue
        if photo_span is not None and photo_span[0] <= address < stop <= photo_span[1]:
            software = (name.startswith(('compiler_rt.addf3.', 'compiler_rt.mulf3.', 'compiler_rt.divf3.', 'compiler_rt.divsf3.', 'compiler_rt.divdf3.', 'compiler_rt.comparef.', 'compiler_rt.float_from_int.', 'compiler_rt.int_from_float.', 'compiler_rt.extendf.', 'compiler_rt.truncf.')) or re.fullmatch(r'__(?:(?:add|sub|mul|div|cmp|eq|ne|ge|gt|le|lt|unord)(?:sf|df)2?3?|float(?:un)?(?:si|di)(?:sf|df)|fix(?:uns)?(?:sf|df)(?:si|di)|extendsfdf2|truncdfsf2)',name))
            automatic = automatic_cards and name.startswith(('card_auto.', 'card.license.Parser(', 'card.service.ServiceType(true,', 'card.wire_policy.PolicyType(true)'))
            require(automatic or name in photo_functions or name.startswith('card.surface.Parser') or name == 'photo_runtime.execute' or software, 'unapproved photo codec function: ' + name)
            continue
        role = "probe" if name == "psram.probe" else "mapping" if re.fullmatch(r"psram_memory\.prepare__func_[0-9]+", name) else None
        require(role is not None and start <= address < stop <= end, "unapproved Flash function: " + name)
        require(role not in found, "duplicate Flash boot role")
        found[role] = {"name": name, "start": hex(address), "end": hex(stop)}
    require(set(found) == {"probe", "mapping"}, "missing approved Flash boot functions")
    ordered = sorted(found.values(), key=lambda entry: int(entry["start"], 16))
    require(int(ordered[0]["start"], 16) == start and int(ordered[-1]["end"], 16) == end and
            0 <= int(ordered[1]["start"], 16) - int(ordered[0]["end"], 16) <= 16,
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


def audit(elf, image, mode=None, profile="device", sqlite_manifest=None, keypad_manifest=None):
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
    allow_sql = mode == "sqlite"
    allow_ui = keypad_manifest is not None
    allow_photo = allow_ui and keypad_manifest.get("codec") is not None
    require(not allow_ui or (mode == 'integer' and profile == 'device' and not allow_sql and keypad_manifest.get('schema') == 1), 'invalid keypad profile/manifest')
    card_code = b""
    card_start = None
    photo_sections = {}
    ui_sections = {}
    ui_pools = []
    require(not allow_sql or (sqlite_manifest is not None and sqlite_manifest.get("schema") == 1 and
                             sqlite_manifest.get("allowed_functions")), "missing SQLite object manifest")
    for section in sections:
        name_id, section_type, flags, address, offset, size, link, _, _, stride = section
        name = string(names, name_id)
        if flags & 2 and size:  # SHF_ALLOC
            if name == ".heap":
                require(section_type == 8 and flags & 7 == 3, "heap must be writable NOBITS")
            in_stacks = name == ".stacks"
            if in_stacks:
                audit_stack_section(section_type, flags, address, size)
            in_sram = low <= address and address + size <= high
            in_ui = name in UI_POOLS
            if in_ui:
                audit_ui_pool(name, section_type, flags, address, size, allow_ui)
                ui_pools.append({'name': name, 'origin': hex(address), 'end': hex(address + size), 'bytes': size})
            if not in_sram and not in_stacks and not in_ui:
                audit_flash_section(name, section_type, flags, address, size, allow_sql, allow_ui, allow_photo)
                require(name not in flash_found, "duplicate mapped Flash section")
                flash_found.add(name)
                if name == '.flash.card':
                    card_start, card_code = address, elf[offset:offset + size]
                if name in PHOTO_SECTIONS:
                    photo_sections[name] = (address, elf[offset:offset + size])
                if name in SQL_SECTIONS:
                    sql_sections[name] = (address, elf[offset:offset + size])
                if name in UI_SECTIONS:
                    ui_sections[name] = (address, elf[offset:offset + size])
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
    require(flash_found == set(FLASH_SECTIONS) | (SQL_SECTIONS if allow_sql else set()) | (UI_SECTIONS if allow_ui else set()) | (PHOTO_SECTIONS if allow_photo else set()) | ({".flash.card"} if allow_ui and keypad_manifest.get("ui_mode") == "runtime" else set()), "missing mapped Flash sections")
    ui_report = None
    ui_payload = None
    if allow_ui:
        require(len(ui_pools) == 2, 'missing keypad SRAM pools')
        pad_start, pad = ui_sections['.flash.uipad']
        start, data = ui_sections['.flash.ui']
        require(pad_start == 0x40010020 + ((len(flash_tables) + 3) & ~3) and not any(pad), 'invalid keypad Flash padding bytes')
        require(symbols.get('__flash_ui_start') == start and symbols.get('__flash_ui_end') == start + len(data), 'invalid keypad Flash symbols')
        audit_ui_assets(start, data, symbols, keypad_manifest)
        ui_payload = flash_tables + bytes((-len(flash_tables)) % 4) + pad + data
        ui_payload += bytes((-len(ui_payload)) % 4)
        ui_report = {'start': hex(start), 'end': hex(start + len(data)), 'bytes': len(data), 'writable': False, 'executable': False,
                     'ui_mode': keypad_manifest.get('ui_mode', 'baked'), 'pools': ui_pools}
        ui_report.update({key: value for key, value in keypad_manifest.items() if key in ('font_sha256', 'font_bytes', 'plan_sha256', 'atlas_sha256', 'atlas_bytes', 'nodes')})
    photo_span = None
    photo_report = None
    if allow_photo:
        codec = keypad_manifest['codec']
        require(codec['name'] == 'OpenJPEG' and codec['version'] == '2.5.4' and codec['decode_only'] is True and codec['io'] is False and codec['threads'] is False and codec['htj2k'] is False, 'unsupported photo codec profile')
        require(codec['archive_sha256'] == 'a695fbe19c0165f295a8531b1e4e855cd94d0875d2f88ec4b61080677e27188a' and codec['workspace_bytes'] == 4*1024*1024-128 and codec['stack_low'] == '0x4ff68000' and codec['stack_high'] == '0x4ff6b000', 'unapproved photo quota/stack/source')
        require(codec['allowed_functions'] == sorted(set().union(*(set(obj['functions']) for obj in codec['objects'].values()))), 'photo function manifest differs from objects')
        code_start, code = photo_sections['.flash.photo']; ro_start, ro = photo_sections['.flash.photo.rodata']
        require(code_start == start + len(data) and ro_start == code_start + len(code) and ro_start + len(ro) <= SQL_END, 'photo sections must be contiguous with read-only UI data')
        require(all(symbols.get(name) == address for name,address in {'__photo_text_start':code_start,'__photo_text_end':ro_start,'__photo_rodata_start':ro_start,'__photo_rodata_end':ro_start+len(ro)}.items()), 'invalid photo section symbols')
        first,last = symbols['__photo_fixture_start'],symbols['__photo_fixture_end']
        require(ro_start <= first < last <= ro_start + len(ro) and hashlib.sha256(ro[first-ro_start:last-ro_start]).hexdigest() == codec['fixture_sha256'], 'synthetic photo fixture mismatch')
        automatic = keypad_manifest.get('automatic_cards')
        jis_first,jis_last=symbols.get('__license_jis_start',0),symbols.get('__license_jis_end',0)
        if automatic:
            require(automatic.get('kinds') == ['mynumber','license'] and automatic.get('credential_budget_per_pin') == 1 and type(automatic.get('read_enabled')) is bool and automatic.get('jis_bytes') == (17672 if automatic['read_enabled'] else 0), 'unapproved automatic card profile')
            require(ro_start <= jis_first <= jis_last <= ro_start+len(ro) and jis_last-jis_first == automatic['jis_bytes'] and (not automatic['read_enabled'] or hashlib.sha256(ro[jis_first-ro_start:jis_last-ro_start]).hexdigest() == automatic['jis_sha256']), 'JIS mapping differs from automatic card manifest')
        else:
            require(jis_first == jis_last, 'licence data without automatic card profile')
        forbidden = {'fopen','fclose','fread','fwrite','fprintf','printf','snprintf','vsnprintf','getenv','opj_create_compress','opj_encode','opj_start_compress','opj_pi_initialise_encode','opj_tcd_rateallocate'}
        require(not forbidden.intersection(symbols), 'I/O/encoding API linked in photo decoder')
        photo_span = (code_start,ro_start)
        ui_payload += code + ro
        ui_payload += bytes((-len(ui_payload))%4)
        photo_report = {'name':codec['name'],'version':codec['version'],'decode_only':True,'text_start':hex(code_start),'text_end':hex(ro_start),'rodata_start':hex(ro_start),'rodata_end':hex(ro_start+len(ro)),'text_bytes':len(code),'rodata_bytes':len(ro),'text_sha256':hashlib.sha256(code).hexdigest(),'rodata_sha256':hashlib.sha256(ro).hexdigest(),'workspace_bytes':codec['workspace_bytes'],'stack_low':codec['stack_low'],'stack_high':codec['stack_high']}
        sizes = [elf[section[4]:section[4]+section[5]] for section in sections if string(names,section[0]) == '.stack_sizes']
        require(len(sizes)==1, 'missing photo C stack metadata')
        photo_report['static_c_stack'] = decode_stack_sizes(sizes[0],functions)
        require(photo_report['static_c_stack']['maximum_reported_frame_bytes'] <= 8192, 'photo C frame exceeds isolated stack margin')
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
    card_span = None if card_start is None else (card_start, card_start + len(card_code))
    if card_span:
        require(card_start == (boot_end + 15) & ~15 and symbols.get('__flash_card_start') == card_start and symbols.get('__flash_card_end') == card_span[1], 'invalid card foreground symbols')
        require(keypad_manifest.get('allowed_functions') == (([] if keypad_manifest.get('automatic_cards') else ['card_read.prepare', 'card_read.run']) + ['keypad_display.prepare', 'keypad_display.paintTextures', 'usb_probe.Device.send', 'usb_probe.Device.scrub', 'usb_probe.Device.powerCut', 'display_runtime.start'] + (['photo_runtime.prepare'] + ([] if keypad_manifest.get('automatic_cards', {}).get('read_enabled') is False else ['photo_runtime.decode']) + ['photo_runtime.close'] if allow_photo else [])), 'unapproved foreground manifest')
        for prefix in keypad_manifest['allowed_functions']:
            require(sum(1 for name, address, stop in functions if card_span[0] <= address < stop <= card_span[1] and (name == prefix or re.fullmatch(re.escape(prefix) + r'__func_[0-9]+', name))) == 1, 'missing/duplicate card foreground entry: ' + prefix)
    boot_functions = audit_boot_functions(functions, boot_start, boot_end, low, high, sql_span, sqlite_manifest['allowed_functions'] if allow_sql else (), card_span, keypad_manifest.get('allowed_functions', ()) if allow_ui else (), photo_span, keypad_manifest['codec']['allowed_functions'] if allow_photo else (), bool(keypad_manifest.get('automatic_cards')) if allow_ui else False)
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
    if allow_ui:
        report['keypad_storage'] = ui_report
        report['memory']['regions'].extend(ui_pools)
        report['memory']['total_bytes'] += sum(pool['bytes'] for pool in ui_pools)
        report['sram_reserved_bytes'] += sum(pool['bytes'] for pool in ui_pools)
    if photo_report is not None:
        report["photo_codec"] = photo_report
        if keypad_manifest.get("automatic_cards"):
            report["automatic_cards"] = keypad_manifest["automatic_cards"]
    if card_span:
        report['card_text'] = {'start': hex(card_start), 'end': hex(card_span[1]), 'bytes': len(card_code), 'sha256': hashlib.sha256(card_code).hexdigest(), 'writable': False, 'executable': True}
    if image is None:
        return report
    require(image[0] == 0xE9 and struct.unpack_from("<I", image, 4)[0] == entry,
            "image entry differs from ELF")
    position = 24
    image_segments = []
    mapped = []
    first_payload = boot_code
    if card_span:
        first_payload += bytes(card_start - boot_end) + card_code
    first_length = 256 + ((len(first_payload) + 3) & ~3)
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
            require(data[256:256 + len(first_payload)] == first_payload, "Flash boot/card bytes differ from ELF")
            report["flash_boot"]["image_offset"] = position + 256
        if address:
            mapped_length = len(ui_payload) if allow_ui else len(sql_payload) if allow_sql else (len(flash_tables) + 3) & ~3
            require((low <= address and address + length <= high) or
                    (address == FLASH_SECTIONS[".flash.appdesc"][0] and length == first_length) or
                    (address == flash_start and length == mapped_length), "unexpected image load range")
            if address in (FLASH_SECTIONS[".flash.appdesc"][0], flash_start):
                require(address % 65536 == position % 65536, "Flash image/MMU offset mismatch")
                mapped.append(address)
            if address == flash_start:
                require(data[:len(flash_tables)] == flash_tables, "mapped Flash bytes differ from ELF")
                if allow_sql:
                    require(data == sql_payload, "merged records/SQLite image bytes differ from ELF")
                    report["sqlite"]["image_offset"] = position + SQL_START - flash_start
                if allow_ui:
                    require(data == ui_payload, 'merged keypad image bytes differ from ELF')
                    report['keypad_storage']['image_offset'] = position + SQL_START - flash_start
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


def audit_loader_config(text, profile):
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
    return {"l2_bytes": 0x20000, "line_bytes": 64, "profile": profile,
            "stack_source_window": {"origin": hex(supported_low), "end": hex(supported_high)},
            "config_sha256": hashlib.sha256(text.encode()).hexdigest()}


def main():
    if len(sys.argv) not in (4, 5, 6, 7, 8, 9, 10):
        raise SystemExit("usage: check-native-image.py ELF BIN|--elf-only REPORT.json [MODE [PROFILE [LOADER.elf [CONFIG.h [SQLITE-MANIFEST.json|--none [KEYPAD-MANIFEST.json]]]]]]")
    try:
        image = None if sys.argv[2] == "--elf-only" else Path(sys.argv[2]).read_bytes()
        report = audit(Path(sys.argv[1]).read_bytes(), image, sys.argv[4] if len(sys.argv) >= 5 else None,
                       sys.argv[5] if len(sys.argv) >= 6 else "device",
                       json.loads(Path(sys.argv[8]).read_text()) if len(sys.argv) >= 9 and sys.argv[8] != '--none' else None,
                       json.loads(Path(sys.argv[9]).read_text()) if len(sys.argv) == 10 else None)
        if len(sys.argv) == 10:
            manifest = json.loads(Path(sys.argv[9]).read_text())
            root = Path(sys.argv[9]).resolve().parents[2]
            if 'codec' in manifest:
                require(all(hashlib.sha256((Path(sys.argv[9]).parent/name).read_bytes()).hexdigest()==obj['sha256'] for name,obj in manifest['codec']['objects'].items()), 'photo object differs from manifest')
            require(all(hashlib.sha256((root / name).read_bytes()).hexdigest() == digest for name, digest in manifest['sources'].items()), 'keypad generated source hashes differ')
        if len(sys.argv) >= 5:
            require(sys.argv[4] in ("integer", "floating", "compiled", "sqlite"), "invalid FP mode")
            require(report["fp_assembly_linked"] == (sys.argv[4] in ("floating", "compiled")), "FP assembly differs from requested mode")
        if len(sys.argv) >= 7:
            report["loader"] = audit_loader(report, Path(sys.argv[6]).read_bytes())
        if len(sys.argv) >= 8:
            report["loader_config"] = audit_loader_config(Path(sys.argv[7]).read_text(), sys.argv[5])
            if 'keypad_storage' in report:
                window = report['loader_config']['stack_source_window']
                require(all(int(window['origin'], 16) <= int(pool['origin'], 16) < int(pool['end'], 16) <= int(window['end'], 16) for pool in report['keypad_storage']['pools']), 'keypad pool outside source-supported SRAM')
    except (ValueError, IndexError, KeyError, struct.error) as error:
        raise SystemExit("Native image audit failed: " + str(error)) from error
    Path(sys.argv[3]).write_text(json.dumps(report, indent=2) + "\n")
    print("Native image audit passed: SRAM runtime, approved Flash boot code/tables, known ROM ABI, no RTOS symbols")


if __name__ == "__main__":
    main()
