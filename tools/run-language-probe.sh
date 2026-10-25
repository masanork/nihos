#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
out_dir="$repo_root/build/language-probe"
include_dir="$repo_root/probes/language/include"
harness="$repo_root/probes/language/harness.c"
zig="$repo_root/.tools/zig-0.17.0/zig"

if [ ! -x "$zig" ]; then
    echo "Zig 0.17.0 is not installed; run sh tools/bootstrap-zig.sh" >&2
    exit 1
fi
command -v cc >/dev/null 2>&1 || { echo "cc is required" >&2; exit 1; }
command -v ar >/dev/null 2>&1 || { echo "ar is required" >&2; exit 1; }
command -v cargo >/dev/null 2>&1 || { echo "cargo is required" >&2; exit 1; }

mkdir -p "$out_dir/c" "$out_dir/zig" "$out_dir/rust"

cc -std=c11 -Os -Wall -Wextra -Wconversion -Werror \
    -I"$include_dir" \
    -c "$repo_root/probes/language/c/probe.c" \
    -o "$out_dir/c/probe.o"
ar rcs "$out_dir/c/libnihos_probe.a" "$out_dir/c/probe.o"

zig_target_args=
if [ "$(uname -s)" = "Darwin" ]; then
    case "$(uname -m)" in
        arm64) zig_arch=aarch64 ;;
        x86_64) zig_arch=x86_64 ;;
        *) echo "unsupported macOS architecture" >&2; exit 1 ;;
    esac
    sdk_version=$(xcrun --sdk macosx --show-sdk-version)
    zig_target_args="-target $zig_arch-macos.$sdk_version"
fi

# Intentional word splitting: zig_target_args is either empty or one option
# followed by one target triple.
# shellcheck disable=SC2086
"$zig" build-lib -Osmall $zig_target_args \
    -femit-bin="$out_dir/zig/libnihos_probe.a" \
    "$repo_root/probes/language/zig/probe.zig"

CARGO_TARGET_DIR="$out_dir/rust/target" cargo build \
    --quiet --release \
    --manifest-path "$repo_root/probes/language/rust/Cargo.toml"
cp "$out_dir/rust/target/release/libnihos_language_probe_rust.a" \
    "$out_dir/rust/libnihos_probe.a"

for language in c zig rust; do
    cc -std=c11 -Os -Wall -Wextra -Wconversion -Werror \
        -I"$include_dir" "$harness" \
        "$out_dir/$language/libnihos_probe.a" \
        -o "$out_dir/$language/probe"
done

c_output=$("$out_dir/c/probe")
zig_output=$("$out_dir/zig/probe")
rust_output=$("$out_dir/rust/probe")
if [ "$c_output" != "$zig_output" ] || [ "$c_output" != "$rust_output" ]; then
    echo "language probe outputs differ" >&2
    printf 'C:    %s\nZig:  %s\nRust: %s\n' \
        "$c_output" "$zig_output" "$rust_output" >&2
    exit 1
fi

results="$out_dir/results.txt"
{
    echo "$c_output"
    echo "zig=$($zig version)"
    echo "rustc=$(rustc --version)"
    echo "cc=$(cc --version 2>/dev/null | sed -n '1p')"
    for language in c zig rust; do
        bytes=$(wc -c < "$out_dir/$language/probe" | tr -d ' ')
        if [ "$(uname -s)" = "Darwin" ]; then
            linked_text=$(size -m "$out_dir/$language/probe" |
                awk '/Section __text:/ { print $3; exit }')
        else
            linked_text=$(size "$out_dir/$language/probe" |
                awk 'NR == 2 { print $1 }')
        fi
        echo "$language executable_bytes=$bytes linked_text_bytes=$linked_text"
    done
} | tee "$results"
