#!/bin/sh
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH='' cd -- "$here/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/nihos-ota-info.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
${CC:-cc} -std=c11 -Wall -Wextra -Werror -I "$here" \
    "$here/nihos_ota_info_wire.c" "$here/ota_info_wire_reference.c" -o "$tmp/reference"
"$tmp/reference" > "$tmp/result.bin"
cmp "$tmp/result.bin" "$repo/src/net/fixtures/hosted-ota-info-v1.bin"
echo 'C6 OTA info wire matches P4 fixture'
