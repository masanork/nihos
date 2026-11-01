#!/bin/sh
# Compile-only: backing regions are borrowed; this does not choose placement.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
zig=${NIHOS_ZIG:-"$root/.tools/zig-0.17.0/zig"}
[ -x "$zig" ] && [ "$("$zig" version)" = 0.17.0 ] || { echo 'Set NIHOS_ZIG to Zig 0.17.0' >&2; exit 1; }
out="$root/build/wamr-arena-rv32"
mkdir -p "$out"
cpu=generic_rv32+m+a+c+zicsr+zifencei
"$zig" build-obj -target riscv32-freestanding-none -mcpu="$cpu" -O ReleaseSafe -fstrip -fno-unwind-tables -femit-bin="$out/arena.o" \
 --dep buddy_heap -Mroot="$root/probes/wamr-arena/arena.zig" \
 -Mbuddy_heap="$root/src/kernel/buddy_heap.zig"
file "$out/arena.o"
