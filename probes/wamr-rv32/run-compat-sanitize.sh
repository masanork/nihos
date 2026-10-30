#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
out="$root/build/wamr-platform-model-sanitize"
mkdir -p "$out"
cc -std=c11 -Wall -Wextra -Werror -Wno-format-truncation \
  -fsanitize=address,undefined -fno-omit-frame-pointer -DNIH_C_TEST_PREFIX \
  -I"$root/include" "$root/src/compat/c_sort.c" "$root/src/compat/c_format.c" \
  "$root/probes/wamr-rv32/compat_test.c" -o "$out/compat-test"
ASAN_OPTIONS=halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 "$out/compat-test"
