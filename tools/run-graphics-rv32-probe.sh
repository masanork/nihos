#!/bin/sh
# Synthetic RV32 link and instruction-level stack measurement, no hardware I/O.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
: "${NIHOS_GRAPHICS_RV32_CXX:?Set NIHOS_GRAPHICS_RV32_CXX to riscv32-esp-elf-g++}"
out="$repo_root/build/graphics-rv32"
mkdir -p "$out"
rm -f "$out/report.json"
NIHOS_GRAPHICS_KERNEL_BACKING=1 sh tools/run-graphics-memory-probe.sh > "$out/memory-base.log" 2>&1
if [ ! -x "$out/venv/bin/python" ]; then python3 -m venv "$out/venv"; fi
"$out/venv/bin/python" -m pip install --force-reinstall --no-deps --require-hashes --only-binary=:all: \
    -r probes/graphics/unicorn-requirements.txt > "$out/unicorn-install.log" 2>&1
python3 probes/graphics/generate_link_oracle.py "$out/generated"
"$out/venv/bin/python" probes/graphics/run_rv32_study.py "$out"
