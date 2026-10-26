#!/bin/sh
# Standalone object, not a runnable native application or a hardware test.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
zig=$(sh "$repo_root/tools/bootstrap-zig.sh")
destination="$repo_root/build/card-service"
mkdir -p "$destination"
"$zig" build-obj -target riscv32-freestanding-none \
    -mcpu=generic_rv32+m+a+c+zicsr+zifencei -O safe -fllvm \
    -femit-bin="$destination/card-service.o" \
    --dep ccid -Mroot="$repo_root/src/card_compile_probe.zig" \
    -target riscv32-freestanding-none \
    -mcpu=generic_rv32+m+a+c+zicsr+zifencei -O safe \
    -Mccid="$repo_root/src/usb/ccid.zig"
echo "card service and PIN entry: RV32 compile-only pass"
