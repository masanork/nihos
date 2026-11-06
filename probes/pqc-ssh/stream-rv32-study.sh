#!/bin/sh
# Compile-only receiver comparison, no firmware, scheduler, or packet capture.
set -eu
: "${ZIG:?set ZIG to Zig 0.17.0}"
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"
[ "$($ZIG version)" = 0.17.0 ]
out="$root/build/pqc-ssh-stream-rv32"
mkdir -p "$out"
cpu=generic_rv32+m+a+c+zicsr+zifencei
for kind in initial full; do
    case "$kind" in initial) enabled=false ;; full) enabled=true ;; esac
    printf 'pub const full = %s;\n' "$enabled" > "$out/options.zig"
    "$ZIG" build-obj -target riscv32-freestanding-none -mcpu="$cpu" -O ReleaseSafe -fllvm \
      --dep stream --dep study_options -Mroot=probes/pqc-ssh/stream_rv32.zig \
      -Mstream=src/net/ssh_stream.zig -Mstudy_options="$out/options.zig" \
      -femit-bin="$out/$kind.o"
    printf '%s ' "$kind"
    python3 probes/pqc-ssh/measure.py "$out/$kind.o"
done
