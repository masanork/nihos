#!/bin/sh
# Execute native context/ABI code with synthetic events, never hardware I/O.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
: "${NIHOS_GRAPHICS_RV32_CXX:?Set NIHOS_GRAPHICS_RV32_CXX to riscv32-esp-elf-g++}"
out="$repo_root/build/graphics-worker"
mkdir -p "$out"
rm -f "$out/report.json"
NIHOS_GRAPHICS_KERNEL_BACKING=1 sh tools/run-graphics-memory-probe.sh > "$out/memory-base.log" 2>&1
if [ ! -x "$out/venv/bin/python" ]; then python3 -m venv "$out/venv"; fi
"$out/venv/bin/python" -m pip install --force-reinstall --no-deps --require-hashes --only-binary=:all: \
    -r probes/graphics/unicorn-requirements.txt > "$out/unicorn-install.log" 2>&1
python3 probes/graphics/generate_link_oracle.py "$out/generated"
zig=${NIHOS_GRAPHICS_ZIG:-}
if [ -z "$zig" ]; then zig=$(sh tools/bootstrap-zig.sh); fi
"$zig" fmt --check probes/graphics/worker/runtime.zig
"$zig" build-obj -O safe -fllvm -ffunction-sections -fdata-sections -fno-stack-check -fno-stack-protector -fcompiler-rt \
    -target riscv32-freestanding-none -mcpu generic_rv32+m+a+c+zicsr+zifencei \
    --dep task_runtime --dep task_calls --dep scheduler -Mroot=probes/graphics/worker/runtime.zig \
    --dep scheduler --dep task_control -Mtask_runtime=src/arch/riscv32/task_runtime.zig \
    --dep task_control -Mtask_calls=src/arch/riscv32/task_calls.zig \
    -Mscheduler=src/kernel/scheduler.zig -Mtask_control=src/kernel/task_control.zig \
    -femit-bin="$out/runtime.o"
"$out/venv/bin/python" probes/graphics/worker/study.py "$out"
