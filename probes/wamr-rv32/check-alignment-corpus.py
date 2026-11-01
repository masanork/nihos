#!/usr/bin/env python3
"""Check corpus identity, generated Wasm instructions, and both RV32 matrices."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
stock, sanitized, out = map(Path, sys.argv[1:])
out.mkdir(parents=True, exist_ok=True)
wasm = stock / 'app.wasm'
assert wasm.read_bytes() == (sanitized / 'app.wasm').read_bytes()
for script in ('test.mjs', 'test-alignment.mjs'):
    subprocess.run(['node', str(root / 'probes/rust-wasm' / script), str(wasm)], check=True)
objdump = os.environ.get('NIHOS_LLVM_OBJDUMP') or shutil.which('llvm-objdump')
if not objdump and shutil.which('xcrun'):
    objdump = subprocess.check_output(['xcrun', '--find', 'llvm-objdump'], text=True).strip()
if not objdump:
    raise SystemExit('Set NIHOS_LLVM_OBJDUMP to an llvm-objdump with Wasm support')
disassembly = subprocess.check_output([objdump, '-d', str(wasm)], text=True)
(out / 'wasm-disassembly.txt').write_text(disassembly)
def function(name):
    match = re.search(r'<'+re.escape(name)+r'>:(.*?)(?=\n[0-9a-f]+ <|\Z)', disassembly, re.S)
    assert match, name
    return match.group(1)
assert re.search(r'i64\.store\s+0:p2align=0', function('nih_probe_unaligned'))
assert re.search(r'i64\.load\s+0:p2align=0', function('nih_probe_unaligned'))
assert 'call_indirect' in function('nih_probe_indirect')
assert 'unreachable' in function('nih_probe_corpus_trap')
assert 'memory.grow' in function('nih_probe_grow')
reports = {}
for label, directory in (('stock', stock), ('sanitized', sanitized)):
    report = json.loads((directory / 'report.json').read_text())
    assert len(report['cases']) == 6
    for file, digest in report['candidate'].items():
        assert hashlib.sha256((directory / file).read_bytes()).hexdigest() == digest
    counts = {}
    for case in report['cases']:
        log = (directory / (case['case'] + '.log')).read_text()
        counts[case['case']] = len(re.findall(r'^NIHOS_WAMR_CORPUS_PASS$', log, re.M))
        assert counts[case['case']] >= 2 and 'NIHOS_WAMR_ALIGN_TRAP' not in log
    reports[label] = {'candidate': report['candidate'], 'corpus_passes': counts}
flags_path = root / 'build/wamr-rv32-align-fixes-compile/CMakeFiles/wamr-rv32-compile.dir/flags.make'
if not flags_path.exists():
    flags_path = root / 'build/wamr-rv32-align-compile/CMakeFiles/wamr-rv32-compile.dir/flags.make'
flags = flags_path.read_text()
assert '-fsanitize=alignment' in flags and '-fno-sanitize-recover=alignment' in flags
(out / 'report.json').write_text(json.dumps({
    'scope': 'RV32 emulator signed test corpus; no physical device or arbitrary-module proof',
    'wasm_sha256': hashlib.sha256(wasm.read_bytes()).hexdigest(),
    'wasm_bytes': wasm.stat().st_size,
    'opcode_checks': ['unaligned i64 load/store', 'call_indirect', 'unreachable', 'memory.grow'],
    'matrices': reports,
}, indent=2) + '\n')
print('Corpus: identical Wasm, verified opcodes and six cases in each RV32 matrix')
