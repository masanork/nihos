#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
wamr="$root/build/wamr-2.4.5"
[ "$(git -C "$wamr" rev-parse HEAD)" = 25bd7eb63e828e4bd242cc9b38d260b4b31c6605 ] || exit 1
out="$root/build/wamr-platform-model"
mkdir -p "$out"
cc -std=c11 -Wall -Wextra -Werror \
  -I"$root/probes/wamr-rv32/platform" \
  -I"$wamr/core/shared/platform/include" \
  "$root/probes/wamr-rv32/platform/nihos_platform.c" \
  "$root/probes/wamr-rv32/platform/model_test.c" \
  -o "$out/model-test"
"$out/model-test"
echo 'WAMR single-owner platform model: ok'
cc -std=c11 -Wall -Wextra -Werror -DNIH_C_TEST_PREFIX \
  -I"$root/include" \
  "$root/src/compat/c_sort.c" \
  "$root/src/compat/c_format.c" \
  "$root/probes/wamr-rv32/compat_test.c" \
  -o "$out/compat-test"
"$out/compat-test"
