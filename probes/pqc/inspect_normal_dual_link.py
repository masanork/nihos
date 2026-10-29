#!/usr/bin/env python3
"""Compare audited device-profile fixture images; no execution claim."""
import hashlib
import json
from pathlib import Path
import struct
import sys

from inspect_combined_xip import FUNCTIONS


def load(elf, image, audit):
    data, binary = Path(elf).read_bytes(), Path(image).read_bytes()
    a = json.loads(Path(audit).read_text())
    if hashlib.sha256(data).hexdigest() != a['elf_sha256'] or hashlib.sha256(binary).hexdigest() != a['image_sha256']:
        raise ValueError('image/ELF hash differs from audit')
    h = struct.unpack_from('<HHIIIIIHHHHHH', data, 16)
    if data[:7] != b'\x7fELF\x01\x01\x01': raise ValueError('expected ELF32')
    sections = [struct.unpack_from('<10I', data, h[5] + i * h[10]) for i in range(h[11])]
    strings = sections[h[12]]; table = data[strings[4]:strings[4]+strings[5]]
    named = {table[s[0]:table.index(0, s[0])].decode(errors='replace'): s for s in sections}
    symbols = {}
    for s in sections:
        if s[1] != 2: continue
        strings = sections[s[6]]; tab = data[strings[4]:strings[4]+strings[5]]
        for off in range(s[4], s[4] + s[5], 16):
            n, value, size, info, _, index = struct.unpack_from('<IIIBBH', data, off)
            if n and index: symbols[tab[n:tab.index(0, n)].decode(errors='replace')] = (value, size, info & 15)
    if a['heap']['bytes'] < 49152 or a['primary_static_bytes'] + a['heap']['bytes'] != 160*1024:
        raise ValueError('primary SRAM floor or accounting mismatch')
    return a, named, symbols


def check(off_elf, off_image, off_audit, off_options, base_elf, base_image, base_audit, base_options, dual_elf, dual_image, dual_audit, dual_options):
    disabled, _, _ = load(off_elf, off_image, off_audit)
    base, _, _ = load(base_elf, base_image, base_audit)
    dual, sections, symbols = load(dual_elf, dual_image, dual_audit)
    off_opts = Path(off_options).read_text()
    base_opts = Path(base_options).read_text()
    if off_opts.replace('pub const pqc_verify_probe = false;', 'pub const pqc_verify_probe = true;').replace('pub const pqc_arena_probe = false;', 'pub const pqc_arena_probe = true;') != base_opts or base_opts != Path(dual_options).read_text():
        raise ValueError('generated options differ unexpectedly')
    if 'pqc_fixture' in disabled: raise ValueError('disabled image contains PQC fixture')
    if 'pub const pqc_worker_probe = false;' not in base_opts: raise ValueError('unexpected experimental worker stack')
    worker_symbol = symbols.get('native_tasks.pqc_worker_stack')
    if worker_symbol is not None and worker_symbol[1] != 0: raise ValueError('unexpected worker-stack reservation')
    old, pqc = base['pqc_fixture'], dual['pqc_fixture']
    excluded = 'PQCP_MLKEM_NATIVE_MLKEM768_keccakf1600_permute'
    if old['profile'] != 'mldsa65-arena-fixture' or pqc['profile'] != 'diagnostic-dual-normal-link-fixture' or pqc['cache_off_qualified'] is not False:
        raise ValueError('wrong fixture profile')
    if set(pqc['functions']) != FUNCTIONS - {excluded} or len(old['functions']) != 11:
        raise ValueError('unexpected Flash function inventory')
    code = sections['.pqc.sram.code']; ro = sections['.pqc.sram.data']
    if not (code[1] == 1 and code[2] == 6 and code[5] == 5668 and ro[1] == 1 and ro[2] & 7 == 2 and ro[5] == 2400 and
            0x4ff00000 <= code[3] < code[3] + code[5] <= 0x4ff28000 and 0x4ff00000 <= ro[3] < ro[3] + ro[5] <= 0x4ff28000):
        raise ValueError('SRAM split section differs')
    if symbols.get(excluded) != (code[3], code[5], 2): raise ValueError('missing SRAM Keccak')
    if symbols.get('test_vector_sk') != (ro[3], ro[5], 1): raise ValueError('missing SRAM test vector')
    for name in ('PQCP_MLDSA_NATIVE_MLDSA65_verify', 'PQCP_MLKEM_NATIVE_MLKEM768_keypair_derand', 'PQCP_MLKEM_NATIVE_MLKEM768_enc_derand', 'PQCP_MLKEM_NATIVE_MLKEM768_dec', 'nih_mlkem_worker_fixture'):
        if name not in pqc['functions']: raise ValueError('missing retained Flash root ' + name)
    return {'qualification': 'device-profile structural link/image study; no physical or KEM execution', 'disabled': {'elf_sha256': disabled['elf_sha256'], 'image_sha256': disabled['image_sha256'], 'primary_static_bytes': disabled['primary_static_bytes'], 'heap_bytes': disabled['heap']['bytes'], 'image_bytes': disabled['image_bytes']}, 'baseline': {'elf_sha256': base['elf_sha256'], 'image_sha256': base['image_sha256'], 'primary_static_bytes': base['primary_static_bytes'], 'heap_bytes': base['heap']['bytes'], 'image_bytes': base['image_bytes'], 'flash_text_bytes': old['text_bytes'], 'flash_rodata_bytes': old['rodata_bytes']}, 'dual': {'elf_sha256': dual['elf_sha256'], 'image_sha256': dual['image_sha256'], 'primary_static_bytes': dual['primary_static_bytes'], 'heap_bytes': dual['heap']['bytes'], 'image_bytes': dual['image_bytes'], 'flash_text_bytes': pqc['text_bytes'], 'flash_rodata_bytes': pqc['rodata_bytes'], 'sram_code_bytes': code[5], 'sram_test_data_bytes': ro[5]}, 'static_delta_from_disabled': dual['primary_static_bytes'] - disabled['primary_static_bytes'], 'static_delta_bytes': dual['primary_static_bytes'] - base['primary_static_bytes'], 'heap_floor_margin_bytes': dual['heap']['bytes'] - 49152, 'hypothetical_heap_after_extra_8192_stack': dual['heap']['bytes'] - 8192, 'hypothetical_floor_deficit': max(0, 49152 - (dual['heap']['bytes'] - 8192))}


if __name__ == '__main__':
    if len(sys.argv) != 14: raise SystemExit('usage: inspect_normal_dual_link.py OFF_ELF OFF_IMAGE OFF_AUDIT OFF_OPTIONS BASE_ELF BASE_IMAGE BASE_AUDIT BASE_OPTIONS DUAL_ELF DUAL_IMAGE DUAL_AUDIT DUAL_OPTIONS OUTPUT.json')
    result = check(*sys.argv[1:13])
    Path(sys.argv[13]).write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
