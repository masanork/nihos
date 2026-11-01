#!/bin/sh
# Hosted 2.13.1 protobuf-c independent Begin/Write/End/Activate; no device access.
set -eu
if [ "$#" -ne 1 ]; then echo "usage: $0 /path/to/esp-hosted-2.13.1" >&2; exit 2; fi
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
source_dir=$1
out=$(mktemp "${TMPDIR:-/tmp}/hosted-ota213-proto.XXXXXX")
trap 'rm -f "$out"' EXIT HUP INT TERM
cc -std=c17 -Wall -Wextra -Werror -I "$source_dir/common/proto" -I "$source_dir/common/protobuf-c" \
  "$root/tools/hosted_ota_213_proto_reference.c" "$source_dir/common/proto/esp_hosted_rpc.pb-c.c" \
  "$source_dir/common/protobuf-c/protobuf-c/protobuf-c.c" -o "$out"
if [ "$("$out")" != 0801108a02180cd21000 ]; then echo 'Hosted 2.13 Activate protobuf differs' >&2; exit 1; fi
# Regenerate the shared Begin/Write/End vectors with 2.13 descriptors too.
cc -std=c17 -Wall -Wextra -Werror -I "$source_dir/common/proto" -I "$source_dir/common/protobuf-c" \
  "$root/tools/hosted_ota_proto_reference.c" "$source_dir/common/proto/esp_hosted_rpc.pb-c.c" \
  "$source_dir/common/protobuf-c/protobuf-c/protobuf-c.c" -o "$out"
actual=$("$out")
expected='08011090021809821100
0801109102180a8a11060a04e90080ff
0801109202180b921100'
if [ "$actual" != "$expected" ]; then echo 'Hosted 2.13 Begin/Write/End protobuf differs' >&2; exit 1; fi
echo 'Hosted 2.13.1 independent Begin/Write/End/Activate protobuf vectors match'
