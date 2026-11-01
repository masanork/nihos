#!/bin/sh
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/nihos-time-wire.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
${CC:-cc} -std=c11 -Wall -Wextra -Werror -I"$here" \
  "$here/nihos_time_wire.c" "$here/wire_test.c" -o "$tmp/wire-test"
"$tmp/wire-test"
printf '%s\n' 'C6 time wire host test passed'
