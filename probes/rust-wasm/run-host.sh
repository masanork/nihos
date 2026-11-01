#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
out="$root/build/rust-wasm-probe"
CARGO_TARGET_DIR="$out" cargo build --locked --release --target wasm32-unknown-unknown --manifest-path "$root/probes/rust-wasm/Cargo.toml"
node "$root/probes/rust-wasm/test.mjs" "$out/wasm32-unknown-unknown/release/nihos_rust_wasm_probe.wasm"
