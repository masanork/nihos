#!/bin/sh
# Host behavior and RV32 code-generation study, never a firmware build.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
zig=${ZIG:?set ZIG to Zig 0.17.0}
kem=${MLKEM_SOURCE:?set MLKEM_SOURCE to pinned mlkem-native checkout}
pin=e0e0ae95765f4c48585dc8cdaa0656d4eda46a06
[ "$(git -C "$kem" rev-parse HEAD)" = "$pin" ] || { echo "ML-KEM revision mismatch" >&2; exit 1; }
[ -z "$(git -C "$kem" status --porcelain --untracked-files=no)" ] || { echo "ML-KEM source modified" >&2; exit 1; }
[ "$($zig version)" = 0.17.0 ] || { echo "Zig version mismatch" >&2; exit 1; }
cd "$root"
out=build/pqc-mlkem-arena
mkdir -p "$out"
"$zig" cc -O2 -std=c11 -DMLK_CONFIG_PARAMETER_SET=768 -DMLK_CONFIG_NO_RANDOMIZED_API \
 -include probes/pqc/mlkem_arena.h -I "$kem/mlkem" -c "$kem/mlkem/mlkem_native.c" -o "$out/mlkem.o"
"$zig" cc -O2 -std=c11 -c probes/pqc/mlkem_arena.c -o "$out/arena.o"
"$zig" test probes/pqc/mlkem_arena_test.zig "$out/mlkem.o" "$out/arena.o" -lc -O ReleaseSafe
cpu=generic_rv32+m+a+c+zicsr+zifencei
headers=$(dirname "$zig")/lib/libc/include
"$zig" cc -target riscv32-freestanding-none -mcpu="$cpu" -O2 -std=c11 -ffreestanding -fno-builtin -ffunction-sections -fdata-sections -fstack-size-section \
 -isystem "$headers/riscv32-linux-musl" -isystem "$headers/generic-musl" \
 -DMLK_CONFIG_PARAMETER_SET=768 -DMLK_CONFIG_NO_RANDOMIZED_API \
 -include probes/pqc/mlkem_arena.h -I "$kem/mlkem" -c "$kem/mlkem/mlkem_native.c" -o "$out/mlkem-rv32.o"
"$zig" cc -target riscv32-freestanding-none -mcpu="$cpu" -O2 -std=c11 -ffreestanding -fno-builtin -ffunction-sections -fdata-sections \
 -isystem "$headers/riscv32-linux-musl" -isystem "$headers/generic-musl" -c probes/pqc/mlkem_arena.c -o "$out/arena-rv32.o"
"$zig" cc -target riscv32-freestanding-none -mcpu="$cpu" -O2 -ffreestanding -fno-builtin -ffunction-sections -fdata-sections -c probes/pqc/runtime.c -o "$out/runtime-rv32.o"
for op in keypair_derand enc_derand dec; do
 "$zig" cc -target riscv32-freestanding-none -mcpu="$cpu" -nostdlib -Wl,--gc-sections -Wl,-e,"PQCP_MLKEM_NATIVE_MLKEM768_$op" \
  "$out/mlkem-rv32.o" "$out/arena-rv32.o" "$out/runtime-rv32.o" -o "$out/$op.elf"
done
python3 - <<'PY'
import hashlib,json,sys
from pathlib import Path
sys.path.insert(0,'probes/pqc')
from measure import sections
out=Path('build/pqc-mlkem-arena')
ops={}
for name in ('keypair_derand','enc_derand','dec'):
 p=out/(name+'.elf')
 ops[name]={'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'allocated_sections':sections(p)}
report={'note':'Standalone link-only RV32; no runtime or firmware proof','operations':ops}
(out/'rv32-report.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
PY
