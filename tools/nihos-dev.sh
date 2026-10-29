#!/bin/sh
# Common entry point for host UI simulation and native target checks.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
command=${1:-help}
if [ "$#" -gt 0 ]; then shift; fi
case "$command" in
    ui) exec python3 tools/card_sim/app.py --application normal "$@" ;;
    card) exec python3 tools/card_sim/app.py --application card "$@" ;;
    check) exec python3 tools/card_sim/app.py --headless build/card-sim/evidence "$@" ;;
    canvas-trace-check) exec sh tools/run-emulator-trace.sh "$@" ;;
    canvas-live-check) exec python3 tools/run-canvas-live-smoke.py "$@" ;;
    canvas-live) exec python3 tools/canvas_live.py "$@" ;;
    canvas-snapshot) exec python3 tools/canvas_snapshot.py "$@" ;;
    canvas-rv32) exec sh tools/run-canvas-offscreen.sh "$@" ;;
    help|-h|--help)
        cat <<'HELP'
nihos development simulator
  sh tools/nihos-dev.sh ui          interactive normal UI in your browser
  sh tools/nihos-dev.sh card        interactive synthetic card UI
  sh tools/nihos-dev.sh check       deterministic host UI scenarios
  sh tools/nihos-dev.sh canvas-rv32 RV32 offscreen canvas qualification
  sh tools/nihos-dev.sh canvas-snapshot capture the RV32 framebuffer as PNG
  sh tools/nihos-dev.sh canvas-live interactive RV32 fixture in your browser
  sh tools/nihos-dev.sh canvas-live-check deterministic RV32 input/frame test
  sh tools/nihos-dev.sh canvas-trace-check record and compare RV32 trace frames

ui/card/check use host code and synthetic devices. canvas-rv32 uses ESP-EMU;
it does not simulate the Tab5 panel or provide a live display. Pass --port to
ui/card. See docs/development-simulator.md for prerequisites and boundaries.
HELP
        ;;
    *) echo "Unknown command: $command (try: sh tools/nihos-dev.sh help)" >&2; exit 2 ;;
esac
