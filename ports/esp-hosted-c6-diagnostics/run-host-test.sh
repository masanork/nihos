#!/bin/sh
set -eu
if [ "$#" -ne 1 ]; then echo "usage: $0 /path/to/hosted-1.4.1/slave" >&2; exit 2; fi
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
slave=$1
out=$(mktemp "${TMPDIR:-/tmp}/nihos-c6-diagnostics-test.XXXXXX")
trap 'rm -f "$out"' EXIT HUP INT TERM
cc -std=c17 -Wall -Wextra -Werror -I "$here" -I "$slave/main/common/proto" \
  -I "$slave/main/common/protobuf-c" "$here/diagnostics_test.c" \
  "$here/nihos_c6_diagnostics.c" "$slave/main/common/proto/esp_hosted_rpc.pb-c.c" \
  "$slave/main/common/protobuf-c/protobuf-c/protobuf-c.c" -o "$out"
"$out"
