#!/bin/sh
set -eu

version=0.17.0
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
install_dir="$repo_root/.tools/zig-$version"

if [ -x "$install_dir/zig" ]; then
    actual_version=$("$install_dir/zig" version)
    if [ "$actual_version" != "$version" ]; then
        echo "unexpected Zig version in $install_dir: $actual_version" >&2
        exit 1
    fi
    echo "$install_dir/zig"
    exit 0
fi

os=$(uname -s)
arch=$(uname -m)
case "$os/$arch" in
    Darwin/arm64)
        archive=zig-aarch64-macos-$version.tar.xz
        sha256=b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a
        ;;
    Darwin/x86_64)
        archive=zig-x86_64-macos-$version.tar.xz
        sha256=4f9a1c5269aa17ebda5e6d3c2b89d6cbf36f7d2b22a0306e9ab98f25f95529c6
        ;;
    Linux/x86_64)
        archive=zig-x86_64-linux-$version.tar.xz
        sha256=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
        ;;
    Linux/aarch64)
        archive=zig-aarch64-linux-$version.tar.xz
        sha256=9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8
        ;;
    *)
        echo "unsupported Zig bootstrap host: $os/$arch" >&2
        exit 1
        ;;
esac

mkdir -p "$repo_root/.tools"
stage=$(mktemp -d "$repo_root/.tools/zig-stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM

curl -fsSL "https://ziglang.org/download/$version/$archive" -o "$stage/$archive"
if command -v sha256sum >/dev/null 2>&1; then
    actual_sha256=$(sha256sum "$stage/$archive" | awk '{print $1}')
else
    actual_sha256=$(shasum -a 256 "$stage/$archive" | awk '{print $1}')
fi
if [ "$actual_sha256" != "$sha256" ]; then
    echo "Zig archive checksum mismatch" >&2
    exit 1
fi

tar -xf "$stage/$archive" -C "$stage"
extracted="$stage/${archive%.tar.xz}"
if [ ! -x "$extracted/zig" ]; then
    echo "Zig archive did not contain the expected compiler" >&2
    exit 1
fi
mv "$extracted" "$install_dir"
echo "$install_dir/zig"
