#!/bin/sh
set -eu

version=0.10.0
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
install_dir="$repo_root/.tools/zlint-$version"
binary="$install_dir/zlint"

if [ -x "$binary" ]; then
    actual_version=$("$binary" --version)
    if [ "$actual_version" != "v$version" ]; then
        echo "unexpected ZLint version in $install_dir: $actual_version" >&2
        exit 1
    fi
    echo "$binary"
    exit 0
fi

os=$(uname -s)
arch=$(uname -m)
case "$os/$arch" in
    Darwin/arm64)
        asset=zlint-macos-aarch64
        sha256=9dcc4b27f450c7ba6707403283b9a44092a41b777356ec7326a611bd9ec67200
        ;;
    Darwin/x86_64)
        asset=zlint-macos-x86_64
        sha256=59f6ad25c625dabdfb4bed6cb640e400c4235fdd5475608966060e548c208b3b
        ;;
    Linux/x86_64)
        asset=zlint-linux-x86_64
        sha256=0b331646d5e40bec3cfcb0694c5da0b13b9de8b10af12937a777ab3144b70b65
        ;;
    Linux/aarch64)
        asset=zlint-linux-aarch64
        sha256=ec5e31eacc889540dbfa0a32f0e694199d06c16f640b832bf2a3bd8ecc07c3e3
        ;;
    *)
        echo "unsupported ZLint bootstrap host: $os/$arch" >&2
        exit 1
        ;;
esac

mkdir -p "$repo_root/.tools"
stage=$(mktemp -d "$repo_root/.tools/zlint-stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM

curl -fsSL \
    "https://github.com/DonIsaac/zlint/releases/download/v$version/$asset" \
    -o "$stage/zlint"
if command -v sha256sum >/dev/null 2>&1; then
    actual_sha256=$(sha256sum "$stage/zlint" | awk '{print $1}')
else
    actual_sha256=$(shasum -a 256 "$stage/zlint" | awk '{print $1}')
fi
if [ "$actual_sha256" != "$sha256" ]; then
    echo "ZLint binary checksum mismatch" >&2
    exit 1
fi

chmod +x "$stage/zlint"
mkdir "$install_dir"
mv "$stage/zlint" "$binary"
echo "$binary"
