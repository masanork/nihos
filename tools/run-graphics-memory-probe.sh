#!/bin/sh
# Independent host experiment; does not change native firmware or access hardware.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
out="$repo_root/build/graphics-probe"
mkdir -p "$out"
rm -f "$out/report.json" "$out/pool-result.json" "$out/font-result.json" "$out/metadata-rv32.o"
kernel_backing=${NIHOS_GRAPHICS_KERNEL_BACKING:-0}
case "$kernel_backing" in 0|1) ;; *) echo 'NIHOS_GRAPHICS_KERNEL_BACKING must be 0 or 1' >&2; exit 1 ;; esac
sanitizers=${NIHOS_GRAPHICS_SANITIZERS:-ON}
case "$sanitizers" in ON|OFF) ;; *) echo 'NIHOS_GRAPHICS_SANITIZERS must be ON or OFF' >&2; exit 1 ;; esac
ASAN_OPTIONS=${ASAN_OPTIONS:-detect_stack_use_after_return=1}
UBSAN_OPTIONS=${UBSAN_OPTIONS:-halt_on_error=1:print_stacktrace=1}
export ASAN_OPTIONS UBSAN_OPTIONS
rm -f "$out/font-buddy-result.json" "$out/pool-buddy-result.json" "$out/backing-test-result.json"
rm -f "$out/font-fragmented-result.json"
buddy_object=
if [ "$kernel_backing" = 1 ]; then
    zig=${NIHOS_GRAPHICS_ZIG:-}
    if [ -z "$zig" ]; then zig=$(sh tools/bootstrap-zig.sh); fi
    if [ "$("$zig" version)" != 0.17.0 ]; then echo 'graphics bridge requires Zig 0.17.0' >&2; exit 1; fi
    NIHOS_GRAPHICS_ZIG_USED=$zig
    export NIHOS_GRAPHICS_ZIG_USED
    mkdir -p "$out/buddy"
    buddy_object="$out/buddy/backing.o"
    "$zig" build-obj -O safe -fllvm -fno-stack-check -fno-stack-protector -fcompiler-rt \
        --dep buddy_heap --dep task_resources -Mroot=probes/graphics/buddy_backing.zig \
        -Mbuddy_heap=src/kernel/buddy_heap.zig -Mtask_resources=src/kernel/task_resources.zig \
        -femit-bin="$buddy_object"
fi
if [ "$(uname -s)" = Darwin ] && [ -z "${MACOSX_DEPLOYMENT_TARGET:-}" ]; then
    MACOSX_DEPLOYMENT_TARGET=$(sw_vers -productVersion)
    export MACOSX_DEPLOYMENT_TARGET
fi
sources=$(python3 probes/graphics/fetch_sources.py)
if ! cmake -S probes/graphics -B "$out/host" -DPROBE_SOURCES="$sources" \
    -DPROBE_SANITIZERS="$sanitizers" -DPROBE_BUDDY_OBJECT="$buddy_object" -DCMAKE_BUILD_TYPE=RelWithDebInfo > "$out/configure.log" 2>&1; then
    tail -60 "$out/configure.log" >&2; exit 1
fi
if ! cmake --build "$out/host" --parallel 4 > "$out/build.log" 2>&1; then
    tail -60 "$out/build.log" >&2; exit 1
fi
"$out/host/pool-test" > "$out/pool-result.json"
"$out/host/font-probe" "$sources/BIZUDGothic-Regular.ttf" "$sources/BIZUDMincho-Regular.ttf" > "$out/font-result.json"
if [ "$kernel_backing" = 1 ]; then
    "$out/host/backing-test" > "$out/backing-test-result.json"
    "$out/host/pool-test-buddy" > "$out/pool-buddy-result.json"
    "$out/host/font-probe-buddy" "$sources/BIZUDGothic-Regular.ttf" "$sources/BIZUDMincho-Regular.ttf" > "$out/font-buddy-result.json"
    NIHOS_GRAPHICS_FRAGMENTED=1 "$out/host/font-probe-buddy" "$sources/BIZUDGothic-Regular.ttf" "$sources/BIZUDMincho-Regular.ttf" > "$out/font-fragmented-result.json"
fi
if [ -n "${NIHOS_GRAPHICS_RV32_CXX:-}" ]; then
    "$NIHOS_GRAPHICS_RV32_CXX" -std=c++17 -Os -fdata-sections -march=rv32imac_zicsr_zifencei -mabi=ilp32 \
        -c probes/graphics/metadata_size.cpp -o "$out/metadata-rv32.o"
    if [ "$kernel_backing" = 1 ]; then
        "$NIHOS_GRAPHICS_RV32_CXX" -std=c++17 -Os -ffunction-sections -fdata-sections \
            -fno-exceptions -fno-rtti -march=rv32imac_zicsr_zifencei -mabi=ilp32 \
            -DNIHOS_GRAPHICS_BUDDY_BACKING=1 -c probes/graphics/lazy_pool.cpp \
            -o "$out/buddy/lazy-pool-rv32.o"
        "$zig" build-obj -O safe -fllvm -fno-stack-check -fno-stack-protector \
            -target riscv32-freestanding-none -mcpu generic_rv32+m+a+c+zicsr+zifencei \
            --dep buddy_heap --dep task_resources -Mroot=probes/graphics/buddy_backing.zig \
            -Mbuddy_heap=src/kernel/buddy_heap.zig -Mtask_resources=src/kernel/task_resources.zig \
            -femit-bin="$out/buddy/backing-rv32.o"
    fi
fi
python3 probes/graphics/report.py "$out" "$sanitizers" "$kernel_backing"
