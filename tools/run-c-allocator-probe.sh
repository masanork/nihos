#!/bin/sh
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
zig=$(sh tools/bootstrap-zig.sh)
out_dir="$repo_root/build/c-allocator"
mkdir -p "$out_dir"
"$zig" build-obj -O safe -fllvm -fno-stack-check -fno-stack-protector \
    --dep buddy_heap --dep task_resources -Mroot=probes/allocator/host.zig \
    -Mbuddy_heap=src/kernel/buddy_heap.zig -Mtask_resources=src/kernel/task_resources.zig \
    -femit-bin="$out_dir/allocator.o"
"$zig" cc -O2 -g -pthread -std=c11 -Wall -Wextra -Wconversion -Werror -I include \
    probes/allocator/host_probe.c probes/allocator/c_probe.c "$out_dir/allocator.o" -o "$out_dir/probe"
"$out_dir/probe"
