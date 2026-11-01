#!/bin/sh
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
hosted=${1:?pass ESP-Hosted 3.0.10 checkout path}
expected=4e029441bc0322b368c19767d91d84c6de197ba1
[ "$(git -C "$hosted" rev-parse HEAD)" = "$expected" ] || { echo 'wrong upstream revision' >&2; exit 1; }
git -C "$hosted" diff --quiet HEAD -- common/serializers/eh_proto_v2 || { echo 'upstream protocol files have local changes' >&2; exit 1; }
codec="$hosted/common/serializers/third_party/msg_codec/protobuf-c"
[ "$(git -C "$codec" rev-parse HEAD)" = abc67a11c6db271bedbb9f58be85d6f4e2ea8389 ] || { echo 'wrong protobuf-c revision' >&2; exit 1; }
git -C "$codec" diff --quiet HEAD || { echo 'protobuf-c has local changes' >&2; exit 1; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/hosted3-ota.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
${CC:-cc} -std=c11 -I "$hosted/common/serializers/eh_proto_v2/include" -I "$codec" \
    "$here/generate-ota-reference.c" "$hosted/common/serializers/eh_proto_v2/src/gen_v2.c" \
    "$codec/protobuf-c/protobuf-c.c" -o "$tmp/generate"
"$tmp/generate" > "$tmp/ota.hex"
cmp "$tmp/ota.hex" "$here/ota-reference.hex"
echo 'Upstream OTA protobuf reference matches P4 test vectors'
