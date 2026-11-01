#!/bin/sh
# RV32 emulator-only alignment instrumentation: one trap and six session paths.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cc=${NIHOS_RISCV_CC:-riscv32-esp-elf-gcc}
out="$root/build/wasm-alignment-session"
NIHOS_NATIVE_WASM_ALIGN_SAN=1 NIHOS_WASM_SESSION_OUT="$out" sh "$root/probes/wamr-native/run-session-emulator.sh"
"${cc%gcc}nm" -A -u "$root/build/wamr-rv32-align-compile/libwamr-rv32-compile.a" > "$out/ubsan-references.txt"
"${cc%gcc}objdump" -h "$out/wamr-combined.o" > "$out/ubsan-sections.txt"
cp "$root/build/wamr-rv32-align-compile/CMakeFiles/wamr-rv32-compile.dir/flags.make" "$out/ubsan-flags.txt"
python3 - "$out" <<'PY'
import json,re,sys
from pathlib import Path
out=Path(sys.argv[1]); flags=(out/'ubsan-flags.txt').read_text(); refs=(out/'ubsan-references.txt').read_text(); sections=(out/'ubsan-sections.txt').read_text()
assert '-fsanitize=alignment' in flags and '-fno-sanitize-recover=alignment' in flags
for name in ('wasm_interp_classic.c.obj','wasm_loader.c.obj','wasm_runtime.c.obj'):
    assert any(name in line and '__ubsan_handle_type_mismatch_v1_abort' in line for line in refs.splitlines()),name
rows=re.findall(r'^\s*\d+\s+\.rodata\.nihos_(?:data|type)\d+\s[^\n]*\n([^\n]+)',sections,re.M)
assert len(rows)>100 and all('READONLY' in flags for flags in rows),len(rows)
assert not re.search(r'^\s*\d+\s+\.(?:data|sdata)\.\.Lubsan_',sections,re.M)
report=json.loads((out/'report.json').read_text()); assert len(report['cases'])==6
for case in report['cases']:
    text=(out/(case['case']+'.log')).read_text()
    assert 'NIHOS_WAMR_ALIGN_TRAP' not in text,case['case']
print(f'RV32 WAMR instrumentation: {len(rows)} readonly metadata sections; interpreter, loader and runtime referenced')
PY
sh "$root/probes/wamr-rv32/run-alignment-negative.sh"
