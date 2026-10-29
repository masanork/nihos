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

ui/card/check use host code and synthetic devices. canvas-rv32 uses ESP-EMU;
it does not simulate the Tab5 panel or provide a live display. Pass --port to
ui/card. See docs/development-simulator.md for prerequisites and boundaries.
HELP
        ;;
    *) echo "Unknown command: $command (try: sh tools/nihos-dev.sh help)" >&2; exit 2 ;;
esac
