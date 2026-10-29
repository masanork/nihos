#!/bin/sh
# Record and replay an identical RV32 pointer trace. No physical device I/O.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
out="$root/build/emulator-trace"
mkdir -p "$out"
rm -f "$out/reference.json" "$out/replay.json"
python3 tools/emulator_trace.py record probes/emulator/canvas-trace.json "$out/reference.json"
python3 tools/emulator_trace.py record probes/emulator/canvas-trace.json "$out/replay.json"
python3 tools/emulator_trace.py compare "$out/reference.json" "$out/replay.json"
