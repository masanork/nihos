#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
out="$root/build/rust-app-probe"
mkdir -p "$out"
CARGO_TARGET_DIR="$out/target" cargo build --release --manifest-path "$root/probes/rust-app/Cargo.toml"
cc -std=c11 -Wall -Wextra -Werror -I"$root/include" "$root/probes/rust-app/host.c" "$out/target/release/libnihos_rust_app_probe.a" -o "$out/host"
"$out/host"
