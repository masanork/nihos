#!/bin/sh
set -eu

version=0.50.0
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
install_dir="$repo_root/.tools/esp-emu-$version"
binary="$install_dir/esp-emu"

if [ -x "$binary" ]; then
    actual_version=$("$binary" --version | tail -n 1)
    if [ "$actual_version" != "esp-emu $version" ]; then
        echo "unexpected ESP-EMU version in $install_dir: $actual_version" >&2
        exit 1
    fi
    echo "$binary"
    exit 0
fi

os=$(uname -s)
arch=$(uname -m)
case "$os/$arch" in
    Darwin/arm64)
        platform=aarch64-apple-darwin
        sha256=3328b4cce9e3338a0ea34767db1f2fdd9a264b126434dfec16a02091e1949eb8
        ;;
    Linux/x86_64)
        platform=x86_64-unknown-linux-gnu
        sha256=3f388f44ae38e829c74d637a68f4d80a136c375ff4d7d168acf87c8d274f0075
        ;;
    Linux/aarch64)
        platform=aarch64-unknown-linux-gnu
        sha256=a25f040348c17286885d4e84cd8f0691ed572eac1f3428d88c2814fe930c83e5
        ;;
    *)
        echo "unsupported ESP-EMU bootstrap host: $os/$arch" >&2
        exit 1
        ;;
esac

archive="esp-emu-$version-$platform.tar.gz"
mkdir -p "$repo_root/.tools"
stage=$(mktemp -d "$repo_root/.tools/esp-emu-stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM

curl -fsSL \
    "https://github.com/espressif/esp-emulator/releases/download/v$version/$archive" \
    -o "$stage/$archive"
if command -v sha256sum >/dev/null 2>&1; then
    actual_sha256=$(sha256sum "$stage/$archive" | awk '{print $1}')
else
    actual_sha256=$(shasum -a 256 "$stage/$archive" | awk '{print $1}')
fi
if [ "$actual_sha256" != "$sha256" ]; then
    echo "ESP-EMU archive checksum mismatch" >&2
    exit 1
fi

tar -xzf "$stage/$archive" -C "$stage"
extracted="$stage/esp-emu-$version-$platform/esp-emu"
if [ ! -x "$extracted" ]; then
    echo "ESP-EMU archive did not contain the expected binary" >&2
    exit 1
fi
mkdir "$install_dir"
mv "$extracted" "$binary"
echo "$binary"
