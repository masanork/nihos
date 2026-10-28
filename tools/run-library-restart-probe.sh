#!/bin/sh
# Host-driven RV32 ISA only. No native firmware build, serial or hardware access.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
: "${NIHOS_GRAPHICS_RV32_CXX:?Set NIHOS_GRAPHICS_RV32_CXX to riscv32-esp-elf-g++}"
out="$repo_root/build/library-restart-final"
mkdir -p "$out/generated"
python3 probes/graphics/generate_link_oracle.py "$out/generated"
python3 - "$out/generated/link_oracle.cpp" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = 'check(nih_graphics_backing_init(inputs->heap,inputs->heap_bytes)==0,"heap init");'
new = 'check(nih_graphics_backing_parents()==0 && nih_graphics_backing_loan_count()==0,"epoch ready");'
assert s.count(old) == 1
p.write_text('// Restart-only: runner initializes backing once and reopens each retired owner.\n' + s.replace(old, new))
PY
.tools/zig-0.17.0/zig build-obj -O safe -fllvm -fno-stack-check -fno-stack-protector \
    -target riscv32-freestanding-none -mcpu generic_rv32+m+a+c+zicsr+zifencei \
    --dep buddy_heap --dep task_resources -Mroot=probes/graphics/buddy_backing.zig \
    -Mbuddy_heap=src/kernel/buddy_heap.zig -Mtask_resources=src/kernel/task_resources.zig \
    -femit-bin="$out/backing-rv32.o"
"$NIHOS_GRAPHICS_RV32_CXX" -Os -std=c++17 -march=rv32imac_zicsr_zifencei -mabi=ilp32 \
    -fno-exceptions -fno-rtti -ffunction-sections -fdata-sections \
    -DPROBE_RV32=1 -DNIHOS_GRAPHICS_BUDDY_BACKING=1 -DNIHOS_GRAPHICS_ALLOCATION_RECORDS=1024 \
    -Iprobes/graphics -Ibuild/graphics-probe/sources/harfbuzz/src \
    -Ibuild/native-emulator-graphics/graphics/build/ft/include -Ibuild/graphics-probe/sources/freetype/include \
    "$out/generated/link_oracle.cpp" probes/graphics/lazy_pool.cpp \
    build/native-emulator-graphics/graphics/build/hb/libharfbuzz.a \
    build/native-emulator-graphics/graphics/build/ft/libfreetype.a "$out/backing-rv32.o" -lm \
    -nostartfiles --specs=nosys.specs -Wl,-T,probes/graphics/restart_link.ld,--gc-sections \
    -Wl,-u,nih_graphics_backing_init,-u,nih_graphics_backing_retire,-u,nih_graphics_backing_reopen \
    -Wl,-u,nih_graphics_backing_recovered,-u,nih_graphics_backing_initial_free \
    -Wl,-u,nih_graphics_backing_peer_allocate,-u,nih_graphics_backing_peer_release,-u,abort \
    "-Wl,-Map,$out/oracle.map" -o "$out/oracle.elf" > "$out/build.log" 2>&1
PYTHONDONTWRITEBYTECODE=1 build/graphics-rv32/venv/bin/python \
    probes/graphics/library_restart.py "$out" "$NIHOS_GRAPHICS_RV32_CXX" > "$out/run.log" 2>&1
