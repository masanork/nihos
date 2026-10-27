#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
zig=$(sh "$repo_root/tools/bootstrap-zig.sh")
zlint=$(sh "$repo_root/tools/bootstrap-zlint.sh")

cd "$repo_root"
"$zig" fmt --check build.zig src probes/allocator/host.zig probes/store/file_probe.zig probes/store/checkpoint_probe.zig probes/store/stream_probe.zig tools/probes/checkpoint_rv32.zig formal/scheduler/replay.zig
"$zlint" --config zlint.json --deny-warnings src build.zig probes/allocator/host.zig probes/store/file_probe.zig probes/store/checkpoint_probe.zig probes/store/stream_probe.zig tools/probes/checkpoint_rv32.zig formal/scheduler/replay.zig
shellcheck tools/*.sh
sh "$repo_root/tools/check-memory-broker.sh"
sh "$repo_root/tools/check-checkpoint-rv32.sh"
sh "$repo_root/tools/check-riscv32-arch.sh"
