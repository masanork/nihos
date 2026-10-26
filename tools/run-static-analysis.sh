#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
zig=$(sh "$repo_root/tools/bootstrap-zig.sh")
zlint=$(sh "$repo_root/tools/bootstrap-zlint.sh")

cd "$repo_root"
"$zig" fmt --check build.zig src probes/allocator/host.zig formal/scheduler/replay.zig tools/probes probes/c6-sdio
"$zlint" --config zlint.json --deny-warnings src build.zig probes/allocator/host.zig formal/scheduler/replay.zig tools/probes probes/c6-sdio
shellcheck tools/*.sh
sh "$repo_root/tools/check-riscv32-arch.sh"
