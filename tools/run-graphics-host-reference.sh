#!/bin/sh
# Rebuild the pinned sanitized host oracle without a pre-existing probe cache.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
zig=$(sh tools/bootstrap-zig.sh)
sources=$(python3 probes/graphics/fetch_sources.py)
out="$repo_root/build/graphics-rv32"
mkdir -p "$out/generated" build/graphics-probe/buddy
python3 probes/graphics/generate_link_oracle.py "$out/generated"
"$zig" build-obj -O safe -fllvm -fno-stack-check -fno-stack-protector -fcompiler-rt \
    --dep buddy_heap --dep task_resources -Mroot=probes/graphics/buddy_backing.zig \
    -Mbuddy_heap=src/kernel/buddy_heap.zig -Mtask_resources=src/kernel/task_resources.zig \
    -femit-bin=build/graphics-probe/buddy/backing.o
cmake -S probes/graphics -B "$out/host" -DPROBE_SOURCES="$sources" \
    -DPROBE_LINK_ORACLE=ON -DPROBE_SANITIZERS=ON -DPROBE_TEXT_ORACLE=OFF \
    -DPROBE_GENERATED="$out/generated" -DPROBE_ALLOCATION_RECORDS=1024 \
    -DPROBE_FT_RENDER_POOL_BYTES=2048 \
    -DPROBE_BUDDY_OBJECT="$repo_root/build/graphics-probe/buddy/backing.o" \
    -DCMAKE_BUILD_TYPE=MinSizeRel > "$out/host-configure.log" 2>&1
cmake --build "$out/host" --target font-link-oracle --parallel 4 > "$out/host-build.log" 2>&1
sh tools/run-runtime-text-reference.sh
python3 - <<'CHECK'
import json
from pathlib import Path
expected = json.loads(Path('docs/measurements/2026-10-28-runtime-text-reference.json').read_text())
actual = json.loads(Path('build/runtime-text-reference/reference.json').read_text())
for field in ('texts', 'frames', 'matrix_hashes'):
    assert actual[field] == expected[field], field
print('Fresh sanitized host reference matches text, layout, ruby and bitmap goldens')
CHECK
