#!/bin/sh
# Signed test corpus on stock and alignment-instrumented RV32 emulator images.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
stock="$root/build/wasm-alignment-corpus-stock-compressed"
san="$root/build/wasm-alignment-corpus-sanitized-compressed"
NIHOS_NATIVE_WASM_ALIGN_CORPUS=1 NIHOS_NATIVE_WASM_ALIGN_FIXES=1 NIHOS_NATIVE_WASM_ALIGN_SAN=0 NIHOS_WASM_SESSION_OUT="$stock" sh "$root/probes/wamr-native/run-session-emulator.sh"
NIHOS_NATIVE_WASM_ALIGN_CORPUS=1 NIHOS_NATIVE_WASM_ALIGN_FIXES=1 NIHOS_NATIVE_WASM_ALIGN_SAN=1 NIHOS_WASM_SESSION_OUT="$san" sh "$root/probes/wamr-native/run-session-emulator.sh"
python3 "$root/probes/wamr-rv32/check-alignment-corpus.py" "$stock" "$san" "$root/build/wasm-alignment-corpus-audit"
sh "$root/probes/wamr-rv32/run-alignment-negative.sh"
sh "$root/probes/wamr-rv32/run-alignment-corpus-negative.sh"
