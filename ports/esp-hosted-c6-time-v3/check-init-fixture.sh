#!/bin/sh
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH='' cd -- "$here/../.." && pwd)
hosted=${1:?pass clean ESP-Hosted 3.0.10 checkout path}
expected=4e029441bc0322b368c19767d91d84c6de197ba1
[ "$(git -C "$hosted" rev-parse HEAD)" = "$expected" ] || { echo 'wrong upstream revision' >&2; exit 1; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/hosted3-init.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
${CC:-cc} -std=c11 -Wall -Wextra -Werror \
    -I "$hosted/common/eh_tlv/include" -I "$hosted/common/eh_common/include" \
    "$here/generate-init-fixture.c" -o "$tmp/generate"
"$tmp/generate" > "$tmp/init.bin"
cmp "$tmp/init.bin" "$repo/src/net/fixtures/hosted-3.0.10-init.bin"
echo 'Upstream TLV fixture matches'
