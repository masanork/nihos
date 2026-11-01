#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
zig=${NIHOS_ZIG:-"$root/.tools/zig-0.17.0/zig"}
if [ ! -x "$zig" ]; then echo 'Set NIHOS_ZIG to the pinned Zig 0.17.0 executable' >&2; exit 1; fi
[ "$($zig version)" = 0.17.0 ] || { echo 'Zig 0.17.0 is required' >&2; exit 1; }
out="$root/build/rust-app-probe"
mkdir -p "$out"
CARGO_TARGET_DIR="$out/target" cargo build --locked --release --manifest-path "$root/probes/rust-app/Cargo.toml"
"$zig" test "$root/src/graphics/surface.zig"
"$zig" build-obj -fPIC "$root/src/graphics/rust_app_probe.zig" -O ReleaseSafe -femit-bin="$out/surface.o"
cc -std=c11 -Wall -Wextra -Werror -I"$root/include" "$root/probes/rust-app/surface_host.c" "$out/surface.o" "$out/target/release/libnihos_rust_app_probe.a" -o "$out/surface-host"
"$out/surface-host"
"$zig" build-obj -fPIC "$root/src/graphics/rust_app_native_fixture.zig" -O ReleaseSafe -femit-bin="$out/owner.o"
cc -std=c11 -Wall -Wextra -Werror -I"$root/include" "$root/probes/rust-app/owner_host.c" "$out/owner.o" "$out/target/release/libnihos_rust_app_probe.a" -o "$out/owner-host"
"$out/owner-host"
CARGO_TARGET_DIR="$out/target" cargo build --locked --release --target riscv32imac-unknown-none-elf --manifest-path "$root/probes/rust-app/Cargo.toml"
"$zig" build-exe -target riscv32-freestanding-none -mcpu generic_rv32+m+a+c+zicsr+zifencei -O ReleaseSafe -fentry=nih_rust_fixture_run -femit-bin="$out/rv32.elf" --dep adapter -Mroot="$root/probes/rust-app/rv32_link.zig" -Madapter="$root/src/graphics/rust_app_probe.zig" "$out/target/riscv32imac-unknown-none-elf/release/libnihos_rust_app_probe.a"
file "$out/rv32.elf"
