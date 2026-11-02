#!/bin/sh
# Compile both codec directions for the P4 ISA; does not run an image.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
zig=$(sh "$repo_root/tools/bootstrap-zig.sh")
out_dir="$repo_root/build/udp-ipv4-rv32"
mkdir -p "$out_dir"
"$zig" build-obj -target riscv32-freestanding-none \
    -mcpu=generic_rv32+m+a+c+zicsr+zifencei -O ReleaseSafe \
    "$repo_root/src/net/udp_ipv4_rv32_probe.zig" -femit-bin="$out_dir/probe.o"
echo 'IPv4 UDP codec RV32 compilation passed (no device execution)'
