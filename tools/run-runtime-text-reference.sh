#!/bin/sh
# Host ASan/UBSan oracle; cached pinned libraries come from graphics RV32 probe.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
out="$repo_root/build/runtime-text-host"
mkdir -p "$out"
python3 probes/graphics/generate_link_oracle.py "$out"
python3 probes/graphics/generate_text_cases.py --header "$out/text_cases.h" probes/graphics/runtime_text_cases.json
/usr/bin/clang++ -std=c++17 -Os -arch arm64 -fsanitize=address,undefined -fno-omit-frame-pointer \
    -ffunction-sections -fdata-sections -fno-exceptions -fno-rtti \
    -DNIHOS_GRAPHICS_BUDDY_BACKING=1 -DNIHOS_GRAPHICS_ALLOCATION_RECORDS=1024 -DPROBE_TEXT_ORACLE=1 \
    -Iprobes/graphics -I"$out" -Ibuild/graphics-probe/sources/harfbuzz/src \
    -Ibuild/graphics-rv32/host/ft/include -Ibuild/graphics-probe/sources/freetype/include \
    "$out/link_oracle.cpp" probes/graphics/lazy_pool.cpp probes/graphics/text_host_main.cpp \
    build/graphics-rv32/host/hb/libharfbuzz.a build/graphics-rv32/host/ft/libfreetype.a \
    build/graphics-probe/buddy/backing.o -lm -o "$out/font-link-oracle" > "$out/build.log" 2>&1
ASAN_OPTIONS=detect_stack_use_after_return=1 UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
    NIHOS_GRAPHICS_RASTER_DIR="$out" "$out/font-link-oracle" \
    build/graphics-probe/sources/BIZUDGothic-Regular.ttf build/graphics-probe/sources/BIZUDMincho-Regular.ttf \
    > "$out/result.json" 2> "$out/result.log"
python3 probes/graphics/runtime_reference.py build/runtime-text-reference
