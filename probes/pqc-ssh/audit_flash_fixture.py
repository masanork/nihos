#!/usr/bin/env python3
"""Strict opt-in audit of the P4 ML-KEM placement fixture, not a runtime safety proof."""
import importlib.util
import os
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
spec = importlib.util.spec_from_file_location('nihos_image_audit', ROOT / 'tools/check-native-image.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)

EXPECTED = frozenset('''nih_pqc_ssh_roots
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
PQCP_MLKEM_NATIVE_MLKEM768_polyvec_frombytes
PQCP_MLKEM_NATIVE_MLKEM768_check_sk
PQCP_MLKEM_NATIVE_MLKEM768_keypair_derand
PQCP_MLKEM_NATIVE_MLKEM768_dec
PQCP_MLKEM_NATIVE_MLKEM768_poly_getnoise_eta1_4x
PQCP_MLKEM_NATIVE_MLKEM768_shake256x4
PQCP_MLKEM_NATIVE_MLKEM768_poly_cbd2
mlk_keccak_absorb_once
mlk_keccak_absorb_once_x4
mlk_keccak_squeezeblocks_x4
PQCP_MLKEM_NATIVE_MLKEM768_keccakf1600_permute
nih_mlkem_alloc
nih_mlkem_free'''.splitlines())
if os.environ.get('NIHOS_PQC_JOB_AUDIT') == '1':
    EXPECTED = (EXPECTED - {'nih_pqc_ssh_roots'}) | {
        'nih_pqc_ssh_job_roots', 'nih_kem_init', 'nih_kem_begin',
        'nih_kem_decaps', 'nih_kem_cancel', 'nih_kem_retire',
    }
original_predicate = audit.xy_function
original_audit = audit.audit_xy_functions

def approved(name):
    return name in EXPECTED or original_predicate(name)

def check_fixture(functions, span):
    for name in EXPECTED:
        matches = [(start, end) for candidate, start, end in functions if candidate == name]
        audit.require(len(matches) == 1 and span[0] <= matches[0][0] < matches[0][1] <= span[1],
                      'PQC fixture function missing, duplicated, or outside Flash: ' + name)
    return original_audit(functions, span)

audit.xy_function = approved
audit.audit_xy_functions = check_fixture

def check_no_resident_copies(elf):
    header = struct.unpack_from('<16sHHIIIIIHHHHHH', elf)
    shoff, entsize, count = header[6], header[11], header[12]
    sections = [struct.unpack_from('<10I', elf, shoff + i * entsize) for i in range(count)]
    resident = [elf[s[4]:s[4] + s[5]] for s in sections
                if s[1] != 8 and s[2] & 2 and 0x4ff00000 <= s[3] < 0x50000000]
    selected = {}
    wanted = EXPECTED | {'mlk_zetas', 'mlk_KeccakF_RoundConstants'}
    for section in sections:
        if section[1] != 2:  # SHT_SYMTAB
            continue
        strings = sections[section[6]]
        table = elf[strings[4]:strings[4] + strings[5]]
        for off in range(section[4], section[4] + section[5], section[9]):
            name_off, value, size, _, _, index = struct.unpack_from('<IIIBBH', elf, off)
            end = table.find(b'\0', name_off)
            if end < 0:
                raise ValueError('invalid symbol name')
            name = table[name_off:end].decode('ascii')
            if name not in wanted:
                continue
            audit.require(name not in selected and index < len(sections), 'duplicate PQC symbol: ' + name)
            parent = sections[index]
            offset = value - parent[3]
            audit.require(0 <= offset and offset + size <= parent[5] and 0x40060000 <= value < 0x40400000 and size >= 32,
                          'PQC symbol is not in mapped Flash: ' + name)
            pattern = elf[parent[4] + offset:parent[4] + offset + size]
            audit.require(not any(pattern in area for area in resident), 'PQC bytes copied to SRAM: ' + name)
            selected[name] = size
    audit.require(set(selected) == wanted, 'missing PQC code or constant symbol')
    audit.require(selected['mlk_zetas'] == 256 and selected['mlk_KeccakF_RoundConstants'] == 192,
                  'PQC constant lengths differ')

if __name__ == '__main__':
    check_no_resident_copies(Path(sys.argv[1]).read_bytes())
    audit.main()
