#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
zig=$(sh "$repo_root/tools/bootstrap-zig.sh")
zlint=$(sh "$repo_root/tools/bootstrap-zlint.sh")

cd "$repo_root"
"$zig" fmt --check build.zig src probes/card_crypto/link.zig probes/card_ui/preview.zig probes/allocator/host.zig formal/scheduler/replay.zig
"$zlint" --config zlint.json --deny-warnings src build.zig probes/card_crypto/link.zig probes/card_ui/preview.zig probes/allocator/host.zig formal/scheduler/replay.zig
shellcheck tools/*.sh
sh "$repo_root/tools/check-riscv32-arch.sh"
