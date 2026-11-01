#!/bin/sh
# Compare the checked-in Zig golden bytes against Hosted 1.4.1 protobuf-c.
# Requires the separately extracted 1.4.1 slave example; never opens a device.
set -eu
if [ "$#" -ne 1 ]; then echo "usage: $0 /path/to/hosted-1.4.1/slave" >&2; exit 2; fi
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
slave=$1
out=$(mktemp "${TMPDIR:-/tmp}/hosted-ota-proto.XXXXXX")
trap 'rm -f "$out"' EXIT HUP INT TERM
cc -std=c17 -Wall -Wextra -Werror -I "$slave/main/common/proto" -I "$slave/main/common/protobuf-c" \
    "$root/tools/hosted_ota_proto_reference.c" "$slave/main/common/proto/esp_hosted_rpc.pb-c.c" \
    "$slave/main/common/protobuf-c/protobuf-c/protobuf-c.c" -o "$out"
actual=$("$out")
expected='08011090021809821100
0801109102180a8a11060a04e90080ff
0801109202180b921100'
if [ "$actual" != "$expected" ]; then echo 'Hosted 1.4.1 protobuf bytes differ' >&2; exit 1; fi
echo 'Hosted 1.4.1 independent protobuf-c OTA request vectors match'
