#!/bin/sh
# Private temporary host image only. No native driver or real block device.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
zig=$(sh "$repo_root/tools/bootstrap-zig.sh")
source=$(python3 "$repo_root/tools/bootstrap-fatfs.py")
cd "$repo_root"
for optimize in Debug ReleaseSafe; do
    "$zig" test -O "$optimize" -lc -DNIHOS_FIXTURE_WRITER=1 \
        -Iprobes/fatfs-disk -I"$source" src/vfs_fatfs_multi_host_test.zig \
        probes/fatfs-multi/fixture.c probes/fatfs-disk/host_disk.c \
        "$source/ff.c" "$source/ffunicode.c"
done
