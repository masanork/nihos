#!/usr/bin/env python3
"""Compare the split test fixture with retained KEM roots and no KEM test vectors."""
import json
from pathlib import Path
import sys

from inspect_normal_dual_link import check as compare, load
from inspect_combined_xip import FUNCTIONS


def check(off_elf, off_image, off_audit, off_options, base_elf, base_image, base_audit, base_options, dual_elf, dual_image, dual_audit, dual_options, roots_elf, roots_image, roots_audit, roots_options):
    result = compare(off_elf, off_image, off_audit, off_options, base_elf, base_image, base_audit, base_options, dual_elf, dual_image, dual_audit, dual_options)
    a, sections, symbols = load(roots_elf, roots_image, roots_audit)
    if Path(base_options).read_bytes() != Path(roots_options).read_bytes(): raise ValueError('roots options differ')
    pqc = a['pqc_fixture']
    moved = {'PQCP_MLKEM_NATIVE_MLKEM768_indcpa_enc', 'PQCP_MLKEM_NATIVE_MLKEM768_indcpa_dec'}
    if pqc['profile'] != 'diagnostic-dual-normal-roots-fixture' or pqc['cache_off_qualified'] is not False or set(pqc['functions']) != FUNCTIONS - moved - {'nih_mlkem_worker_fixture'}:
        raise ValueError('unexpected Flash function inventory')
    for name in ('PQCP_MLDSA_NATIVE_MLDSA65_verify', 'PQCP_MLKEM_NATIVE_MLKEM768_keypair_derand', 'PQCP_MLKEM_NATIVE_MLKEM768_enc_derand', 'PQCP_MLKEM_NATIVE_MLKEM768_dec'):
        if name not in pqc['functions']: raise ValueError('missing retained root ' + name)
    if any(name in symbols for name in ('nih_mlkem_worker_fixture', 'test_vector_d', 'test_vector_z', 'test_vector_m', 'test_vector_pk', 'test_vector_sk', 'test_vector_ct', 'test_vector_ss')):
        raise ValueError('KEM test fixture or vectors unexpectedly retained')
    if '.pqc.sram.data' in sections: raise ValueError('unexpected SRAM test data')
    code = sections['.pqc.sram.code']
    if not (code[1] == 1 and code[2] == 6 and 0x4ff00000 <= code[3] < code[3]+code[5] <= 0x4ff28000):
        raise ValueError('invalid SRAM code section')
    ranges = sorted((symbols[name][0], symbols[name][0] + symbols[name][1]) for name in moved)
    if not (ranges[0][0] == code[3] and ranges[-1][1] == code[3] + code[5] and ranges[0][1] <= ranges[1][0]):
        raise ValueError('SRAM KEM functions do not fill code section')
    opts = Path(roots_options).read_text()
    if 'pub const pqc_worker_probe = false;' not in opts: raise ValueError('unexpected worker enabled')
    stack = symbols.get('native_tasks.pqc_worker_stack')
    if stack is not None and stack[1] != 0: raise ValueError('unexpected worker-stack reservation')
    roots = {'elf_sha256': a['elf_sha256'], 'image_sha256': a['image_sha256'], 'primary_static_bytes': a['primary_static_bytes'], 'heap_bytes': a['heap']['bytes'], 'image_bytes': a['image_bytes'], 'sram_code_bytes': code[5], 'flash_text_bytes': pqc['text_bytes'], 'flash_rodata_bytes': pqc['rodata_bytes'], 'flash_text_remaining': 0x40010000 - int(pqc['text_end'], 16), 'flash_rodata_remaining': 0x40020000 - int(pqc['rodata_end'], 16)}
    roots['static_delta_from_disabled'] = roots['primary_static_bytes'] - result['disabled']['primary_static_bytes']
    roots['static_delta_from_mldsa'] = roots['primary_static_bytes'] - result['baseline']['primary_static_bytes']
    roots['heap_floor_margin_bytes'] = roots['heap_bytes'] - 49152
    roots['hypothetical_heap_after_extra_8192_stack'] = roots['heap_bytes'] - 8192
    roots['hypothetical_margin'] = roots['hypothetical_heap_after_extra_8192_stack'] - 49152
    result['retained_roots'] = roots
    result['qualification'] = 'device-profile structural image study; no KEM runtime or dedicated worker'
    return result


if __name__ == '__main__':
    if len(sys.argv) != 18: raise SystemExit('usage: inspect_normal_roots_link.py OFF_ELF OFF_IMG OFF_AUDIT OFF_OPTIONS BASE_ELF BASE_IMG BASE_AUDIT BASE_OPTIONS DUAL_ELF DUAL_IMG DUAL_AUDIT DUAL_OPTIONS ROOTS_ELF ROOTS_IMG ROOTS_AUDIT ROOTS_OPTIONS OUTPUT.json')
    result = check(*sys.argv[1:17])
    Path(sys.argv[17]).write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
