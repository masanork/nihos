#!/bin/sh
# Compile/link only: credit/MMIO are stubs, and there is no boot entry.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
out=${1:-"$repo_root/build/hosted-long-link"}
mkdir -p "$out"
zig=$(sh "$repo_root/tools/bootstrap-zig.sh")
"$zig" build-exe -target riscv32-freestanding-none \
    -mcpu=generic_rv32+m+a+c+f+zicsr+zifencei -OReleaseSafe \
    -fno-stack-check -fno-stack-protector -fno-strip \
    -fentry=nih_hosted_long_send_compile_probe \
    -T "$repo_root/probes/hosted-long-send/link.ld" \
    -femit-bin="$out/hosted-long.elf" \
    --dep hosted_long_sender --dep sdio --dep hosted_long_dma_guard --dep hosted_long_cache \
    "-Mroot=$repo_root/tools/probes/hosted-long-send.zig" \
    "-Mhosted_long_sender=$repo_root/src/net/hosted_long_sender.zig" \
    "-Msdio=$repo_root/src/soc/esp32p4/sdio.zig" \
    "-Mhosted_long_dma_guard=$repo_root/src/net/hosted_long_dma_guard.zig" \
    "-Mhosted_long_cache=$repo_root/src/platform/native/hosted_long_cache.zig"
python3 "$repo_root/tools/check-hosted-long-link.py" "$out/hosted-long.elf" > "$out/audit.json"
cat "$out/audit.json"
python3 "$repo_root/tools/test_hosted_long_link.py" "$out/hosted-long.elf"
