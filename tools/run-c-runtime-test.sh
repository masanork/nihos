#!/bin/sh
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
mkdir -p build/c-runtime
cc -O2 -g -std=c11 -ffreestanding -fno-builtin -Wall -Wextra -Wconversion -Werror \
    -fsanitize=address,undefined -fno-omit-frame-pointer -DNIH_C_TEST_PREFIX -I include \
    src/compat/c_strings.c probes/sqlite/c_runtime_test.c -o build/c-runtime/test
build/c-runtime/test
