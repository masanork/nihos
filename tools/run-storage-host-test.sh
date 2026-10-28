#!/bin/sh
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
source=$(sh tools/bootstrap-littlefs.sh)
out=build/storage-host
mkdir -p "$out"
cc -O1 -g -std=c11 -fsanitize=address,undefined -fno-omit-frame-pointer \
    -DLFS_NO_DEBUG -DLFS_NO_WARN -DLFS_NO_ERROR -I "$source" \
    probes/storage/make_fixture.c "$source/lfs.c" "$source/lfs_util.c" -o "$out/make-fixture"
cc -O1 -g -std=c11 -Wall -Wextra -Werror -Wno-unused-function -fsanitize=address,undefined -fno-omit-frame-pointer \
    -DLFS_READONLY -DLFS_NO_MALLOC -DLFS_NO_DEBUG -DLFS_NO_WARN -DLFS_NO_ERROR \
    -I "$source" -I include -I src/services probes/storage/host_test.c probes/storage/littlefs_ro.c src/services/storage_littlefs.c \
    "$source/lfs.c" "$source/lfs_util.c" -o "$out/readonly-test"
expected=$(python3 -c 'import zlib; print("%08x" % zlib.crc32(bytes((i*17+3)&255 for i in range(1300))))')
cc -O1 -g -std=c11 -Wall -Wextra -Werror -Wno-unused-function -fsanitize=address,undefined -fno-omit-frame-pointer \
    -DLFS_READONLY -DLFS_NO_MALLOC -DLFS_NO_DEBUG -DLFS_NO_WARN -DLFS_NO_ERROR \
    -I "$source" -I include -I src/services probes/storage/api_test.c src/services/storage_littlefs.c \
    "$source/lfs.c" "$source/lfs_util.c" -o "$out/api-test"
for geometry in 512 4096; do
    "$out/make-fixture" "$out/fixture-$geometry.bin" "$geometry"
    "$out/readonly-test" "$out/fixture-$geometry.bin" "$expected" "$geometry"
    "$out/api-test" "$out/fixture-$geometry.bin"
done
