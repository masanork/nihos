#!/bin/sh
# Experimental SDK/runtime checks; no board, protected storage or scanout claim.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
NIHOS_ZIG=${NIHOS_ZIG:-"$repo_root/.tools/zig-0.17.0/zig"}
export NIHOS_ZIG
cd "$repo_root"
"$NIHOS_ZIG" build test-app --summary all
sh probes/rust-app/run-host.sh
sh probes/rust-app/run-surface.sh
sh probes/wamr-host/run.sh
sh probes/wamr-rv32/run-platform-model.sh
sh probes/wamr-arena/run.sh
sh probes/wamr-native/run-package-process.sh
sh probes/wamr-native/run-journal-wamr-host.sh
