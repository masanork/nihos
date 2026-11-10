#!/bin/sh
# Host-only integration: real xy model, simulated entropy and network owner.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
ZIG=${ZIG:-"$ROOT/.tools/zig-0.17.0/zig"}
cd "$ROOT"
"$ZIG" test -O ReleaseSafe \
    --dep ssh_terminal_session --dep text_console --dep terminal_adapter --dep ssh_lifecycle \
    -Mroot=src/xy/ssh_terminal_host_probe.zig \
    --dep vt100 --dep terminal_adapter -Mssh_terminal_session=src/xy/ssh_terminal_session.zig \
    --dep terminal_adapter -Mvt100=src/net/vt100.zig \
    -Mterminal_adapter=src/net/terminal_adapter.zig -Mview_config=src/xy/view_config.zig \
    --dep view_config --dep canvas -Mtext_console=src/console.zig \
    --dep surface -Mcanvas=src/graphics/canvas.zig -Msurface=src/graphics/surface.zig \
    -Mssh_lifecycle=src/xy/ssh_lifecycle.zig
