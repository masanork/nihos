#!/usr/bin/env python3
"""Compare a gated baseline and explicitly ungated diagnostic ELF, not firmware."""
import hashlib
import json
from pathlib import Path
import re
import struct
import sys

from check_worker_log import stack_symbol
from measure import sections


def inspect(path):
    data = Path(path).read_bytes()
    if data[:7] != b'\x7fELF\x01\x01\x01': raise ValueError('expected ELF32 little-endian')
    h = struct.unpack_from('<HHIIIIIHHHHHH', data, 16)
    ss = [struct.unpack_from('<10I', data, h[5] + i * h[10]) for i in range(h[11])]
    names = {}
    for s in ss:
        if s[1] != 2: continue
        table = ss[s[6]]
        strings = data[table[4]:table[4] + table[5]]
        for off in range(s[4], s[4] + s[5], 16):
            n, value, size, info, _, index = struct.unpack_from('<IIIBBH', data, off)
            if n and index:
                name = strings[n:strings.index(0, n)].decode(errors='replace')
                names[name] = (value, size, info & 15)
    start, end = names['__heap_start'][0], names['__heap_end'][0]
    base, stack_bytes = stack_symbol(data)
    shstr = ss[h[12]]
    shnames = data[shstr[4]:shstr[4] + shstr[5]]
    bss = [s for s in ss if shnames[s[0]:shnames.index(0, s[0])] == b'.bss']
    if len(bss) != 1 or not (bss[0][3] <= base < base + stack_bytes <= bss[0][3] + bss[0][5]):
        raise ValueError('worker stack outside BSS')
    if not (0x4ff20000 <= start <= end == 0x4ff48000 and stack_bytes == 8192):
        raise ValueError('unexpected emulator SRAM layout')
    dsa = sorted(x for x, v in names.items() if v[2] == 2 and x.startswith('PQCP_MLDSA_NATIVE_'))
    kem = sorted(x for x, v in names.items() if v[2] == 2 and x.startswith('PQCP_MLKEM_NATIVE_'))
    for required in ('PQCP_MLKEM_NATIVE_MLKEM768_keypair_derand', 'PQCP_MLKEM_NATIVE_MLKEM768_enc_derand', 'PQCP_MLKEM_NATIVE_MLKEM768_dec'):
        if required not in kem: raise ValueError('missing ML-KEM root ' + required)
    if dsa and 'PQCP_MLDSA_NATIVE_MLDSA65_verify' not in dsa: raise ValueError('missing ML-DSA verification root')
    return {'elf_sha256': hashlib.sha256(data).hexdigest(), 'primary_static_bytes': start - 0x4ff20000, 'heap_start': hex(start), 'heap_end': hex(end), 'heap_bytes': end-start, 'worker_stack_start': hex(base), 'worker_stack_bytes': stack_bytes, 'mlkem_function_count': len(kem), 'mldsa_function_count': len(dsa), 'allocated_sections': sections(Path(path))}


def check(base_elf, diagnostic_elf, base_options, diagnostic_options, fail_log):
    baseline, diagnostic = inspect(base_elf), inspect(diagnostic_elf)
    a, b = Path(base_options).read_text(), Path(diagnostic_options).read_text()
    flag = 'pub const pqc_combined_probe = '
    lines_a = [x for x in a.splitlines() if x.startswith(flag)]
    lines_b = [x for x in b.splitlines() if x.startswith(flag)]
    if lines_a != [flag + 'false;'] or lines_b != [flag + 'true;'] or a.replace(lines_a[0], '') != b.replace(lines_b[0], ''):
        raise ValueError('build options differ beyond combined mode')
    if 'native SRAM heap below 48 KiB' not in Path(fail_log).read_text(errors='replace'):
        raise ValueError('missing normal-gate failure')
    if not (baseline['heap_bytes'] >= 49152 > diagnostic['heap_bytes'] and baseline['mldsa_function_count'] == 0 and diagnostic['mldsa_function_count'] > 0 and baseline['mlkem_function_count'] > 0 and diagnostic['mlkem_function_count'] > 0):
        raise ValueError('algorithms or expected heap boundary not present')
    return {'qualification': 'link-only diagnostic with 48 KiB assertion removed; not a firmware image', 'baseline': baseline, 'combined_diagnostic': diagnostic, 'static_delta_bytes': diagnostic['primary_static_bytes'] - baseline['primary_static_bytes'], 'heap_floor_deficit_bytes': 49152 - diagnostic['heap_bytes']}


if __name__ == '__main__':
    if len(sys.argv) != 7: raise SystemExit('usage: inspect_combined_link.py BASE_ELF DIAG_ELF BASE_OPTIONS DIAG_OPTIONS FAIL_LOG OUTPUT.json')
    result = check(*sys.argv[1:6])
    Path(sys.argv[6]).write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
