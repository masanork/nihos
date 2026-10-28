#!/bin/sh
set -eu

# Build dependencies on Ubuntu: cmake g++ libcurl4-openssl-dev libdw-dev
# libelf-dev libssl-dev zlib1g-dev. Keep the tool outside the measured source tree.
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
install_dir="$repo_root/.tools/kcov-43"
revision=a39874f938ce13f7a65f253120d1ec946b349ffe
sha256=dac01569171979477b500924be264d2a1bc649dae6010536228cbb319344d516

if [ -x "$install_dir/bin/kcov" ]; then
    echo "$install_dir/bin/kcov"
    exit 0
fi
mkdir -p "$repo_root/.tools"
stage=$(mktemp -d "$repo_root/.tools/kcov-stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
curl -fsSL "https://codeload.github.com/SimonKagstrom/kcov/tar.gz/$revision" -o "$stage/source.tar.gz"
actual_sha256=$(sha256sum "$stage/source.tar.gz" | awk '{print $1}')
if [ "$actual_sha256" != "$sha256" ]; then
    echo "kcov archive checksum mismatch" >&2
    exit 1
fi
tar -xf "$stage/source.tar.gz" -C "$stage"
cmake -S "$stage/kcov-$revision" -B "$stage/build" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$install_dir" >&2
cmake --build "$stage/build" --parallel 2 >&2
cmake --install "$stage/build" >&2
echo "$install_dir/bin/kcov"
