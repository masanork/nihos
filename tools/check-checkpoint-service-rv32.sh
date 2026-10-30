#!/bin/sh
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
zig=$(sh "$repo_root/tools/bootstrap-zig.sh")
out_dir=${1:-"$repo_root/build/store-service"}
mkdir -p "$out_dir"
"$zig" build-obj -target riscv32-freestanding-none -mcpu=generic_rv32+m+a+c+zicsr+zifencei -O safe \
    --dep checkpoint_service --dep spsc_ring --dep timer_group "-Mroot=$repo_root/tools/probes/checkpoint_service_rv32.zig" \
    -target riscv32-freestanding-none -mcpu=generic_rv32+m+a+c+zicsr+zifencei -O safe \
    "-Mcheckpoint_service=$repo_root/src/storage/checkpoint_service.zig" \
    -target riscv32-freestanding-none -mcpu=generic_rv32+m+a+c+zicsr+zifencei -O safe \
    "-Mspsc_ring=$repo_root/src/kernel/spsc_ring.zig" \
    -target riscv32-freestanding-none -mcpu=generic_rv32+m+a+c+zicsr+zifencei -O safe \
    "-Mtimer_group=$repo_root/src/soc/esp32p4/timer_group.zig" \
    -femit-bin="$out_dir/service-rv32.o" -femit-asm="$out_dir/service-rv32.s"
echo 'Checkpoint service RV32 / owned mailbox / u64 offsets: compile-only ok'
