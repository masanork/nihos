#!/bin/sh
# Link-only P4-ISA study. No actual worker, SSH runtime, or firmware.
set -eu
: "${ZIG:?set ZIG to Zig 0.17.0}"
: "${NIHOS_MLKEM_ARCHIVE:?set NIHOS_MLKEM_ARCHIVE to the pinned source tarball}"
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"
[ "$($ZIG version)" = 0.17.0 ]
out="$root/build/pqc-ssh-rv32"
mkdir -p "$out"
archive=$(cd "$(dirname "$NIHOS_MLKEM_ARCHIVE")" && pwd)/$(basename "$NIHOS_MLKEM_ARCHIVE")
python3 - "$archive" "$out" <<'PY'
import hashlib, pathlib, sys, tarfile
archive, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
assert hashlib.sha256(archive.read_bytes()).hexdigest() == 'b9f225b455ef268d2469aee26bdd6f6e47e7b24762849bf180074b79ed2db1c4'
prefix = 'mlkem-native-e0e0ae95765f4c48585dc8cdaa0656d4eda46a06/mlkem/'
with tarfile.open(archive) as tar:
    members = [m for m in tar.getmembers() if m.name.startswith(prefix)]
    for m in members:
        if out.resolve() not in (out / m.name).resolve().parents or m.issym() or m.islnk() or not (m.isfile() or m.isdir()):
            raise ValueError('unsafe source archive')
    tar.extractall(out, members=members)
PY
kem="$out/mlkem-native-e0e0ae95765f4c48585dc8cdaa0656d4eda46a06/mlkem"
headers="$(dirname "$ZIG")/lib/libc/include"
cpu=generic_rv32+m+a+c+zicsr+zifencei
for name in mlkem arena runtime roots; do
    case "$name" in
        mlkem) src="$kem/mlkem_native.c" ;;
        arena) src="$root/probes/pqc-ssh/mlkem_arena.c" ;;
        runtime) src="$root/probes/pqc-ssh/runtime.c" ;;
        roots) src="$root/probes/pqc-ssh/rv32_roots.c" ;;
    esac
    "$ZIG" cc -target riscv32-freestanding-none -mcpu="$cpu" -O2 -std=c11 -ffreestanding -fno-builtin -ffunction-sections -fdata-sections \
      -isystem "$headers/riscv32-linux-musl" -isystem "$headers/generic-musl" -DMLK_CONFIG_PARAMETER_SET=768 -DMLK_CONFIG_NO_RANDOMIZED_API \
      -include probes/pqc-ssh/mlkem_arena.h -I "$kem" -c "$src" -o "$out/$name.o"
done
"$ZIG" cc -target riscv32-freestanding-none -mcpu="$cpu" -nostdlib -Wl,--gc-sections -Wl,-e,nih_pqc_ssh_roots \
  "$out/mlkem.o" "$out/arena.o" "$out/runtime.o" "$out/roots.o" -o "$out/combined.elf"
python3 probes/pqc-ssh/measure.py "$out/combined.elf"
for name in kem_job job_roots; do
    "$ZIG" cc -target riscv32-freestanding-none -mcpu="$cpu" -O2 -std=c11 -ffreestanding -fno-builtin -ffunction-sections -fdata-sections -fstack-size-section \
      -isystem "$headers/riscv32-linux-musl" -isystem "$headers/generic-musl" \
      -c "$root/probes/pqc-ssh/$name.c" -o "$out/$name.o"
done
"$ZIG" cc -target riscv32-freestanding-none -mcpu="$cpu" -nostdlib -Wl,--gc-sections -Wl,-e,nih_pqc_ssh_job_roots \
  "$out/mlkem.o" "$out/arena.o" "$out/runtime.o" "$out/kem_job.o" "$out/job_roots.o" -o "$out/job-combined.elf"
python3 probes/pqc-ssh/measure.py "$out/job-combined.elf"
"$ZIG" build-obj -target riscv32-freestanding-none -mcpu="$cpu" -O ReleaseSafe -fllvm \
  --dep handoff -Mroot=probes/pqc-ssh/handoff_rv32.zig -Mhandoff=src/net/ssh_kem_handoff.zig \
  -femit-bin="$out/handoff.o"
python3 probes/pqc-ssh/measure.py "$out/handoff.o"
