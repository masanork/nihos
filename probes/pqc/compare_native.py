#!/usr/bin/env python3
"""Link isolated PQ Code Package and Zig entrypoints; no nihos firmware."""
import json
import os
from pathlib import Path
import re
import subprocess
from measure import sections

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'build/pqc-compare'
ZIG = Path(os.environ['ZIG']).resolve()
KEM = Path(os.environ['MLKEM_SOURCE']).resolve()
DSA = Path(os.environ['MLDSA_SOURCE']).resolve()
PINS = {KEM: 'e0e0ae95765f4c48585dc8cdaa0656d4eda46a06', DSA: '33031ee66dfe0231cc5995dd1d4ced467df6b8de'}
CPU = 'generic_rv32+m+a+c+zicsr+zifencei'
TARGET = ['-target', 'riscv32-freestanding-none', '-mcpu=' + CPU]

def run(args):
    subprocess.run([str(x) for x in args], check=True)

def prologue(asm, symbol):
    match = re.search(r'^' + re.escape(symbol) + r':[^\n]*\n(.*?)(?=^\s*\.Lfunc_end\d+:)', asm, re.M | re.S)
    if not match:
        raise ValueError('function absent: ' + symbol)
    total, registers, align = 0, {}, None
    for line in match[1].splitlines():
        line = line.split('#', 1)[0].strip()
        if re.match(r'(call|tail|j|b\w+)\s', line):
            break
        m = re.fullmatch(r'lui\s+(\w+),\s*(-?\d+)', line)
        if m: registers[m[1]] = int(m[2]) * 4096
        m = re.fullmatch(r'addi\s+(\w+),\s*(\w+),\s*(-?\d+)', line)
        if m:
            d, s, val = m[1], m[2], int(m[3])
            if d == s == 'sp' and val < 0: total -= val
            elif s in registers: registers[d] = registers[s] + val
            elif d != 'sp': registers.pop(d, None)
        m = re.fullmatch(r'sub\s+sp,\s*sp,\s*(\w+)', line)
        if m:
            if m[1] not in registers: raise ValueError('unknown adjustment')
            total += registers[m[1]]
        m = re.fullmatch(r'andi\s+sp,\s*sp,\s*(-?\d+)', line)
        if m: align = -int(m[1])
    return {'fixed_bytes': total, 'align_down_bytes': align}

def main():
    for path, pin in PINS.items():
        actual = subprocess.check_output(['git', '-C', str(path), 'rev-parse', 'HEAD'], text=True).strip()
        if actual != pin: raise ValueError(f'{path}: expected {pin}, got {actual}')
        if subprocess.check_output(['git', '-C', str(path), 'status', '--porcelain', '--untracked-files=no'], text=True).strip():
            raise ValueError(f'{path}: tracked source changes')
    OUT.mkdir(parents=True, exist_ok=True)
    headers = ZIG.parent / 'lib/libc/include'
    flags = [str(ZIG), 'cc', *TARGET, '-O2', '-ffreestanding', '-fno-builtin', '-ffunction-sections', '-fdata-sections', '-isystem', headers / 'riscv32-linux-musl', '-isystem', headers / 'generic-musl']
    run(flags + ['-c', ROOT / 'probes/pqc/runtime.c', '-o', OUT / 'runtime.o'])
    configs = [('mlkem', KEM / 'mlkem', ['-DMLK_CONFIG_NO_RANDOMIZED_API', '-DMLK_CONFIG_PARAMETER_SET=768']), ('mldsa', DSA / 'mldsa', ['-DMLD_CONFIG_PARAMETER_SET=65', '-DMLD_CONFIG_REDUCE_RAM', '-DMLD_CONFIG_NO_RANDOMIZED_API', '-DMLD_CONFIG_NO_SIGN_API', '-DMLD_CONFIG_NO_KEYPAIR_API'])]
    for name, source, defs in configs:
        cmd = flags + ['-I', source, *defs, source / (name + '_native.c')]
        run(cmd + ['-c', '-o', OUT / (name + '.o')])
        run(cmd + ['-S', '-o', OUT / (name + '.s')])
    roots = {'verify': ('mldsa', 'PQCP_MLDSA_NATIVE_MLDSA65_verify'), 'keygen': ('mlkem', 'PQCP_MLKEM_NATIVE_MLKEM768_keypair_derand'), 'encaps': ('mlkem', 'PQCP_MLKEM_NATIVE_MLKEM768_enc_derand'), 'decaps': ('mlkem', 'PQCP_MLKEM_NATIVE_MLKEM768_dec')}
    report = {'pins': {str(k.name): v for k, v in PINS.items()}, 'target': TARGET, 'c_optimization': '-O2', 'operations': {}}
    for op, (lib, symbol) in roots.items():
        path = OUT / (op + '.elf')
        run([ZIG, 'cc', *TARGET, '-nostdlib', '-Wl,--gc-sections', '-Wl,-e,' + symbol, OUT / (lib + '.o'), OUT / 'runtime.o', '-o', path])
        zig_elf = OUT / ('zig-' + op + '.elf')
        zig_obj = ROOT / 'build/pqc-resource' / (op + '.o')
        if not zig_obj.exists(): raise ValueError('run measure.py first')
        run([ZIG, 'cc', *TARGET, '-nostdlib', '-Wl,--gc-sections', '-Wl,-e,pqc_' + op, zig_obj, OUT / 'runtime.o', '-o', zig_elf])
        report['operations'][op] = {'linked_sections': sections(path), 'entry_prologue': prologue((OUT / (lib + '.s')).read_text(), symbol), 'zig_linked_sections': sections(zig_elf)}
    report['mldsa_verify_internal_prologue'] = prologue((OUT / 'mldsa.s').read_text(), 'PQCP_MLDSA_NATIVE_MLDSA65_verify_internal')
    (OUT / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))

if __name__ == '__main__': main()
