#!/bin/sh
# Diagnostic: exits nonzero when UBSan detects undefined behavior.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
mode=${1:-classic}
case "$mode" in classic) fast=0 ;; fast) fast=1 ;; *) echo 'usage: run-ubsan.sh [classic|fast]' >&2; exit 1 ;; esac
wamr="$root/build/wamr-2.4.5"
[ "$(git -C "$wamr" rev-parse HEAD)" = 25bd7eb63e828e4bd242cc9b38d260b4b31c6605 ] || exit 1
[ -z "$(git -C "$wamr" status --porcelain)" ] || exit 1
sh "$root/probes/wamr-host/run-small.sh"
build="$root/build/wamr-ubsan-$mode"
cmake -S "$root/probes/wamr-host" -B "$build" -DWAMR_ROOT_DIR="$wamr" -DCMAKE_BUILD_TYPE=Debug -DNIHOS_WAMR_FAST="$fast" \
 '-DCMAKE_C_FLAGS=-fsanitize=undefined -fno-omit-frame-pointer' '-DCMAKE_EXE_LINKER_FLAGS=-fsanitize=undefined'
cmake --build "$build" --parallel 4
UBSAN_OPTIONS=halt_on_error=1 "$build/nihos-wamr-host" "$root/build/rust-wasm-small/wasm32-unknown-unknown/release/nihos_rust_wasm_probe.wasm"
