#!/bin/sh
# Synthetic fixtures only; sanitizer checks never use real card images.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
destination="$repo_root/build/photo-host-asan"
NIHOS_PHOTO_SANITIZE=1 sh "$repo_root/tools/build-photo-codec.sh" "$destination" host
"$repo_root/.tools/zig-0.17.0/zig" cc -fsanitize=address,undefined -fno-omit-frame-pointer \
    -I "$repo_root/probes/photo" "$repo_root/probes/photo/test.c" \
    "$destination"/photo_*.o -o "$destination/test"
for fixture in "$repo_root"/probes/photo/fixtures/*.jp2 "$repo_root"/probes/photo/fixtures/*.j2k; do
    "$destination/test" "$fixture" "$fixture.rgb565"
done
