#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
[ -x "$root/build/wamr-host/nihos-wamr-host" ] || { echo "Run probes/wamr-host/run.sh first" >&2; exit 1; }
# Application-specific build: 16 KiB stack, one 64 KiB page, no growth.
RUSTFLAGS='-C link-arg=-zstack-size=16384 -C link-arg=--initial-memory=65536 -C link-arg=--max-memory=65536' \
 CARGO_TARGET_DIR="$root/build/rust-wasm-small" cargo build --locked --release --target wasm32-unknown-unknown --manifest-path "$root/probes/rust-wasm/Cargo.toml"
module="$root/build/rust-wasm-small/wasm32-unknown-unknown/release/nihos_rust_wasm_probe.wasm"
node "$root/probes/rust-wasm/test.mjs" "$module"
"$root/build/wamr-host/nihos-wamr-host" "$module" 4194304 fixed-memory
