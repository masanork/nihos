#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
zig=$(sh "$repo_root/tools/bootstrap-zig.sh")
zlint=$(sh "$repo_root/tools/bootstrap-zlint.sh")

cd "$repo_root"
"$zig" fmt --check build.zig src probes/allocator/host.zig probes/fatfs-disk/*.zig formal/scheduler/replay.zig
"$zlint" --config zlint.json --deny-warnings src build.zig probes/allocator/host.zig probes/fatfs-disk/*.zig formal/scheduler/replay.zig
shellcheck tools/*.sh
sh "$repo_root/tools/check-memory-broker.sh"
sh "$repo_root/tools/check-riscv32-arch.sh"
