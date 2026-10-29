#!/usr/bin/env python3
"""Structural link study only; no device image audit or cache-safety claim."""
import hashlib
import json
from pathlib import Path
import struct
import sys

from inspect_combined_link import inspect

# Fixture-specific observed functions, pinned to these exact upstream builds.
# This is a diagnostic inventory, not a reviewed production call-graph proof.
FUNCTIONS = set('''
PQCP_MLDSA_NATIVE_MLDSA65_poly_uniform
PQCP_MLDSA_NATIVE_MLDSA65_poly_challenge
PQCP_MLDSA_NATIVE_MLDSA65_polyvecl_chknorm
PQCP_MLDSA_NATIVE_MLDSA65_polyvec_matrix_pointwise_montgomery_row_lazy
PQCP_MLDSA_NATIVE_MLDSA65_verify_internal
mld_H
PQCP_MLDSA_NATIVE_MLDSA65_verify
PQCP_MLDSA_NATIVE_MLDSA65_keccakf1600_permute
nih_pqc_arena_alloc
nih_pqc_arena_free
nih_pqc_arena_fixture
PQCP_MLKEM_NATIVE_MLKEM768_poly_compress_d10
PQCP_MLKEM_NATIVE_MLKEM768_poly_frommsg
PQCP_MLKEM_NATIVE_MLKEM768_poly_tomsg
PQCP_MLKEM_NATIVE_MLKEM768_gen_matrix
PQCP_MLKEM_NATIVE_MLKEM768_poly_rej_uniform_x4
PQCP_MLKEM_NATIVE_MLKEM768_poly_rej_uniform
PQCP_MLKEM_NATIVE_MLKEM768_indcpa_keypair_derand
PQCP_MLKEM_NATIVE_MLKEM768_polyvec_ntt
PQCP_MLKEM_NATIVE_MLKEM768_polyvec_mulcache_compute
PQCP_MLKEM_NATIVE_MLKEM768_polyvec_reduce
PQCP_MLKEM_NATIVE_MLKEM768_indcpa_enc
PQCP_MLKEM_NATIVE_MLKEM768_polyvec_basemul_acc_montgomery_cached
PQCP_MLKEM_NATIVE_MLKEM768_polyvec_invntt_tomont
PQCP_MLKEM_NATIVE_MLKEM768_indcpa_dec
PQCP_MLKEM_NATIVE_MLKEM768_check_pk
PQCP_MLKEM_NATIVE_MLKEM768_polyvec_frombytes
PQCP_MLKEM_NATIVE_MLKEM768_check_sk
PQCP_MLKEM_NATIVE_MLKEM768_keypair_derand
PQCP_MLKEM_NATIVE_MLKEM768_enc_derand
PQCP_MLKEM_NATIVE_MLKEM768_dec
PQCP_MLKEM_NATIVE_MLKEM768_poly_getnoise_eta1_4x
PQCP_MLKEM_NATIVE_MLKEM768_shake256x4
PQCP_MLKEM_NATIVE_MLKEM768_poly_cbd2
mlk_keccak_absorb_once
mlk_keccak_absorb_once_x4
mlk_keccak_squeezeblocks_x4
PQCP_MLKEM_NATIVE_MLKEM768_keccakf1600_permute
nih_mlkem_alloc
nih_mlkem_free
nih_mlkem_worker_fixture
'''.split())


def xip_sections(path):
    data = Path(path).read_bytes()
    h = struct.unpack_from('<HHIIIIIHHHHHH', data, 16)
    sections = [struct.unpack_from('<10I', data, h[5] + i * h[10]) for i in range(h[11])]
    shstr = sections[h[12]]
    names = data[shstr[4]:shstr[4] + shstr[5]]
    found = {}
    for s in sections:
        name = names[s[0]:names.index(0, s[0])].decode(errors='replace')
        if name in ('.flash.pqc', '.flash.pqc.rodata'):
            if name in found: raise ValueError('duplicate XIP section')
            found[name] = s
    if set(found) != {'.flash.pqc', '.flash.pqc.rodata'}: raise ValueError('missing XIP section')
    code, ro = found['.flash.pqc'], found['.flash.pqc.rodata']
    if not (code[1] == 1 and code[2] == 6 and 0x40000120 < code[3] < code[3] + code[5] <= 0x40010000 and code[3] % 16 == 0 and
            ro[1] == 1 and ro[2] & 7 == 2 and ro[2] & ~50 == 0 and 0x40010020 < ro[3] < ro[3] + ro[5] <= 0x40020000 and ro[3] % 16 == 0):
        raise ValueError('invalid Flash section permissions or bounds')
    segments = [struct.unpack_from('<8I', data, h[4] + i * h[8]) for i in range(h[9])]
    for s, flags in ((code, 5), (ro, 4)):
        if not any(p[0] == 1 and p[6] == flags and p[2] <= s[3] and s[3] + s[5] <= p[2] + p[4] and s[4] - p[1] == s[3] - p[2] for p in segments):
            raise ValueError('Flash section not in corresponding load segment')
    functions, symbols = [], {}
    for s in sections:
        if s[1] != 2: continue
        strings_section = sections[s[6]]
        strings = data[strings_section[4]:strings_section[4] + strings_section[5]]
        for off in range(s[4], s[4] + s[5], 16):
            n, value, size, info, _, index = struct.unpack_from('<IIIBBH', data, off)
            if n and index:
                name = strings[n:strings.index(0, n)].decode(errors='replace')
                symbols[name] = value
                if info & 15 == 2 and code[3] <= value < code[3] + code[5]: functions.append((value, value + size, name))
    start, end = code[3], code[3] + code[5]
    ordered = sorted(functions)
    if not (len(ordered) == len(FUNCTIONS) and {x[2] for x in ordered} == FUNCTIONS and ordered[0][0] == start and ordered[-1][1] == end and all(start <= a < b <= end for a, b, _ in ordered) and all(0 <= right[0] - left[1] <= 16 for left, right in zip(ordered, ordered[1:]))):
        raise ValueError('unexpected, overlapping or unaccounted Flash functions')
    if any(symbols.get(name) != value for name, value in {'__native_pqc_xip': 1, '__flash_pqc_start': start, '__flash_pqc_end': end, '__flash_pqc_rodata_start': ro[3], '__flash_pqc_rodata_end': ro[3]+ro[5]}.items()):
        raise ValueError('XIP marker or boundary symbols mismatch')
    return {name: {'address': hex(s[3]), 'bytes': s[5], 'flags': s[2], 'sha256': hashlib.sha256(data[s[4]:s[4] + s[5]]).hexdigest()} for name, s in found.items()} | {'function_count': len(ordered)}


def check(sram_elf, xip_elf, sram_options, xip_options, xip_layout, failure_log):
    sram, xip = inspect(sram_elf), inspect(xip_elf)
    if Path(sram_options).read_bytes() != Path(xip_options).read_bytes(): raise ValueError('generated options differ')
    if 'ASSERT(__heap_end - __heap_start >= 49152' not in Path(xip_layout).read_text(): raise ValueError('48 KiB linker gate missing')
    if 'native SRAM heap below 48 KiB' not in Path(failure_log).read_text(errors='replace'): raise ValueError('missing normal all-SRAM failure')
    if not (sram['heap_bytes'] < 49152 <= xip['heap_bytes'] and sram['mlkem_function_count'] == xip['mlkem_function_count'] and sram['mldsa_function_count'] == xip['mldsa_function_count'] and xip['mldsa_function_count'] > 0 and xip['mlkem_function_count'] > 0):
        raise ValueError('heap or algorithm roots differ')
    return {'qualification': 'ELF link study only; no image audit, execution or cache-off safety', 'all_sram_diagnostic': sram, 'combined_xip': xip, 'flash': xip_sections(xip_elf), 'static_sram_saved': sram['primary_static_bytes'] - xip['primary_static_bytes'], 'heap_above_floor': xip['heap_bytes'] - 49152}


if __name__ == '__main__':
    if len(sys.argv) != 8: raise SystemExit('usage: inspect_combined_xip.py SRAM_ELF XIP_ELF SRAM_OPTIONS XIP_OPTIONS XIP_LAYOUT FAILURE_LOG OUTPUT.json')
    result = check(*sys.argv[1:7])
    Path(sys.argv[7]).write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
