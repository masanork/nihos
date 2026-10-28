#!/bin/sh
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
zig=$(sh "$repo_root/tools/bootstrap-zig.sh")
out_dir=${1:-"$repo_root/build/checkpoint"}
mkdir -p "$out_dir"
"$zig" build-obj -target riscv32-freestanding-none -mcpu=generic_rv32+m+a+c+zicsr+zifencei -O safe \
    --dep checkpoint_model "-Mroot=$repo_root/tools/probes/checkpoint_rv32.zig" \
    -target riscv32-freestanding-none -mcpu=generic_rv32+m+a+c+zicsr+zifencei -O safe \
    "-Mcheckpoint_model=$repo_root/src/storage/checkpoint_model.zig" \
    -femit-bin="$out_dir/checkpoint-rv32.o" -femit-asm="$out_dir/checkpoint-rv32.s"
echo "Checkpoint RV32 / 16 GiB / u64 media-address compilation: ok (not target execution)"
