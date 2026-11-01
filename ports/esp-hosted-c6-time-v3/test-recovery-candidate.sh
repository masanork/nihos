#!/bin/sh
# Host-only recovery-candidate transfer to an in-memory C6, no device access.
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH='' cd -- "$here/../.." && pwd)
candidate=${1:?pass the reviewed 2.13.1 recovery application binary}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/nihos-hosted3-recovery.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
cp "$candidate" "$tmp/candidate.bin"
cp "$here/recovery213_candidate_host_test.zig" "$tmp/test.zig"
for file in hosted.zig hosted_ota.zig hosted_ota_pump.zig hosted_ota_fake.zig; do
    cp "$repo/src/net/$file" "$tmp/$file"
done
zig=$(sh "$repo/tools/bootstrap-zig.sh")
"$zig" test "$tmp/test.zig"
