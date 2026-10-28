#!/bin/sh
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
zig=$(sh "$repo_root/tools/bootstrap-zig.sh")
out_dir=${1:-"$repo_root/build/memory-broker"}
mkdir -p "$out_dir"
python3 "$repo_root/tools/generate_memory_profile.py" --check
"$zig" fmt --check "$repo_root/tools/probes/memory_broker.zig"
"$zig" build-obj -target riscv32-freestanding-none -mcpu=generic_rv32+m+a+c+zicsr+zifencei -O safe \
    --dep development_memory "-Mroot=$repo_root/tools/probes/memory_broker.zig" \
    -target riscv32-freestanding-none -mcpu=generic_rv32+m+a+c+zicsr+zifencei -O safe \
    "-Mdevelopment_memory=$repo_root/src/kernel/development_memory.zig" \
    -femit-bin="$out_dir/broker-rv32.o" -femit-asm="$out_dir/broker-rv32.s"
echo "Memory broker RV32 compilation and profile generation: ok (not target execution)"
