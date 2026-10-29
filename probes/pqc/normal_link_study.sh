#!/bin/sh
# Link-size diagnostic only; the output is not an executable native firmware.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
zig=${ZIG:-"$root/.tools/zig-0.17.0/zig"}
objdir=${PQC_OBJECT_DIR:-"$root/build/native-device-network-devices"}
out=${PQC_STUDY_DIR:-"$root/build/pqc-normal-link-study"}
mkdir -p "$out"
for name in runtime standalone_observer; do
    "$zig" cc -target riscv32-freestanding-none -mcpu=generic_rv32+m+a+c+zicsr+zifencei \
        -O2 -ffreestanding -fno-builtin -ffunction-sections -fdata-sections \
        -c "$root/probes/pqc/$name.c" -o "$out/$name.o"
done
"$zig" cc -target riscv32-freestanding-none -mcpu=generic_rv32+m+a+c+zicsr+zifencei \
    -nostdlib -Wl,--gc-sections -Wl,-e,nih_pqc_arena_fixture \
    "$objdir/pqc_mldsa_native.o" "$objdir/pqc_native_arena_verify.o" \
    "$out/runtime.o" "$out/standalone_observer.o" -o "$out/fixture.elf"
python3 - "$root/probes/pqc" "$out/fixture.elf" <<'PY'
import json,sys
from pathlib import Path
sys.path.insert(0,sys.argv[1])
from measure import sections
print(json.dumps(sections(Path(sys.argv[2])),sort_keys=True))
PY
