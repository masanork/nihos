#!/bin/sh
# Private, opt-in native fixture: no hardware, no SDK source modifications.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
: "${NIHOS_GRAPHICS_RV32_CXX:?Set NIHOS_GRAPHICS_RV32_CXX to riscv32-esp-elf-g++}"
out=$1
mkdir -p "$out/graphics/generated"
sources=$(python3 probes/graphics/fetch_sources.py)
python3 probes/graphics/generate_link_oracle.py "$out/graphics/generated"
cmake -S probes/graphics -B "$out/graphics/build" \
    -DCMAKE_TOOLCHAIN_FILE="$repo_root/probes/graphics/rv32_toolchain.cmake" \
    -DPROBE_LINK_ORACLE=ON -DPROBE_TASK_ORACLE=OFF -DPROBE_NATIVE_OBJECT=ON \
    -DPROBE_SANITIZERS=OFF -DPROBE_FT_RENDER_POOL_BYTES=2048 -DPROBE_ALLOCATION_RECORDS=1024 \
    -DPROBE_BUDDY_OBJECT= -DPROBE_GENERATED="$out/graphics/generated" -DPROBE_SOURCES="$sources" \
    > "$out/graphics/configure.log" 2>&1
cmake --build "$out/graphics/build" --parallel 4 > "$out/graphics/build.log" 2>&1
python3 probes/graphics/native_payload.py "$out" "$NIHOS_GRAPHICS_RV32_CXX"
