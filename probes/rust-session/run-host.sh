#!/bin/sh
# Same OS session and display-owner copy for native Rust and admitted WAMR.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
zig=${NIHOS_ZIG:-"$root/.tools/zig-0.17.0/zig"}
out="$root/build/rust-session-host"
# Prepares immutable test journals and the same-process admission library.
sh "$root/probes/wamr-native/run-journal-wamr-host.sh"
mkdir -p "$out"
CARGO_TARGET_DIR="$out/rust-target" cargo build --locked --release \
    --manifest-path "$root/probes/rust-app/Cargo.toml"
cp "$out/rust-target/release/libnihos_rust_app_probe.a" "$out/libnative.a"
"$zig" build-obj -fPIC -O ReleaseSafe -femit-bin="$out/session.o" "$root/src/app/session.zig"
"$zig" build-obj -fPIC -O ReleaseSafe -femit-bin="$out/presenter.o" "$root/src/graphics/app_presenter.zig"
"$zig" build-obj -fPIC -O ReleaseSafe -femit-bin="$out/adapter.o" "$root/src/graphics/rust_app_probe.zig"
cmake -S "$root/probes/wamr-host" -B "$out/runtime" \
    -DWAMR_ROOT_DIR="$root/build/wamr-2.4.5" \
    -DNIHOS_BOOT_LIBRARY="$root/build/journal-wamr-host/libboot-admission.a" \
    -DNIHOS_SESSION_DIR="$out" -DCMAKE_BUILD_TYPE=Release > "$out/build.log" 2>&1
cmake --build "$out/runtime" --target nihos-app-session --parallel 4 >> "$out/build.log" 2>&1
"$out/runtime/nihos-app-session" "$root/build/journal-wamr-host/trust.bin" \
    "$root/build/journal-wamr-host/counter.bin" "$root/build/journal-wamr-host/package.bin" \
    "$root/build/journal-wamr-host/root.pub" | tee "$out/session.log"
