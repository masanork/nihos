#!/usr/bin/env python3
"""Audit the synthetic standalone link; never a native ESP32-P4 image audit."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys


def load_inspector():
    path = Path(__file__).with_name('check-sqlite-rv32-object.py')
    spec = importlib.util.spec_from_file_location('sqlite_object', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.inspect


def record(directory):
    directory = Path(directory)
    inspect = load_inspector()
    image = inspect(directory / 'sqlite-link.elf', expected_type=2)
    if image['undefined_symbols']:
        raise ValueError('unresolved runtime symbols: ' + str(image['undefined_symbols']))
    abi = 2 if directory.name == 'ilp32f' else 0
    if image['float_abi_bits'] != abi or image['abi_fingerprint'][9:11] != [0, 0]:
        raise ValueError('unexpected linked ABI or changed SQLite REAL declarations')
    required = {'nih_sqlite_link_probe', 'nih_sqlite_session_open', 'nih_sqlite_session_eval',
                'nih_sqlite_session_close', 'nih_sqlite_session_owner', 'nih_sqlite_session_active',
                'nih_sqlite_session_cancel', 'sqlite3_open', 'sqlite3_os_init', 'sqlite3_os_end'}
    if not required.issubset(image['defined_symbols']):
        raise ValueError('missing actual SQLite/session/oracle implementations')
    all_defined = set(image['defined_symbols']) | set(image['local_defined_symbols'])
    forbidden = {'malloc', 'free', 'realloc', 'calloc', 'localtime', 'gmtime', 'strftime'}
    if forbidden.intersection(all_defined):
        raise ValueError('unexpected libc allocator/time implementation')
    runtime = inspect(directory / 'strings.o')
    if runtime['undefined_symbols']:
        raise ValueError('C compatibility functions unexpectedly depend on another runtime')
    for symbol in ('memcpy', 'memmove', 'memset', 'memcmp', 'strlen'):
        if symbol not in all_defined:
            raise ValueError('missing compiler_rt memory primitive: ' + symbol)
    sqlite_object = inspect(directory / 'sqlite3.o')
    discarded_apis = sorted(set(sqlite_object['defined_symbols']) - all_defined)
    if not {'sqlite3_backup_init', 'sqlite3_complete'}.issubset(discarded_apis):
        raise ValueError('expected unreachable SQLite APIs were not removed')
    result = {'schema': 1, 'evidence': 'standalone-link-only', 'abi': directory.name,
              'source_policy': {'sqlite_real_retained': True, 'sqlite_utc_only': True,
                                'sqlite_zero_malloc': True, 'zig_safety_mode': 'safe'},
              'layout': 'synthetic code 0x41000000, data 0x51000000; not a board map',
              'native_image_linked': False, 'target_code_executed': False,
              'boot_crt_or_stacks_provided': False, 'linker_gc_applied': True, 'discarded_public_sqlite_apis': discarded_apis,
              'oracle_static_heap_buffer_bytes': 262144,
              'firmware_budget_or_peak_stack_claimed': False,
              'elf': {key: value for key, value in image.items() if key not in ('defined_symbols', 'local_defined_symbols', 'sections')},
              'allocated_sections': image['sections'],
              'defined_symbol_count': len(all_defined),
              'compiler_rt_memory_symbols_present': ['memcpy','memmove','memset','memcmp','strlen'],
              'compatibility_object': {key: value for key, value in runtime.items() if key not in ('sections', 'defined_symbols', 'local_defined_symbols')},
              'inputs_sha256': {name: hashlib.sha256((directory / name).read_bytes()).hexdigest()
                                 for name in ('sqlite3.o', 'session.o', 'strings.o', 'vfs.o')}}
    (directory / 'link-report.json').write_text(json.dumps(result, indent=2) + '\n')
    print(directory.name, 'linked text', image['executable_section_bytes'],
          'rodata', image['read_only_allocated_bytes'], 'data/BSS', image['writable_allocated_bytes'],
          'undefined', len(image['undefined_symbols']))


if __name__ == '__main__':
    record(sys.argv[1])
