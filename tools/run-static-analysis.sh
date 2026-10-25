#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
zig=$(sh "$repo_root/tools/bootstrap-zig.sh")
zlint=$(sh "$repo_root/tools/bootstrap-zlint.sh")

cd "$repo_root"
"$zig" fmt --check build.zig src
"$zlint" --config zlint.json --deny-warnings src build.zig
shellcheck tools/*.sh
sh "$repo_root/tools/check-riscv32-arch.sh"
