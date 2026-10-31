#!/bin/sh
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
zig=$(sh tools/bootstrap-zig.sh)
out="$repo_root/build/xy-animation"
mkdir -p "$out"
"$zig" test src/app/animation.zig -O ReleaseSafe
"$zig" test src/app/plot_app.zig -O ReleaseSafe
"$zig" test -O ReleaseSafe --dep view_config -Mroot=src/xy/live_workspace.zig -Mview_config=src/xy/view_config.zig
cc -std=c11 -Wall -Wextra -Werror -I include -fsyntax-only tools/probes/app_protocol.c
"$zig" build-exe -target riscv32-freestanding-none -mcpu=generic_rv32+m+a+c+zicsr+zifencei \
    -O ReleaseSafe -fentry=nih_animation_frame -fcompiler-rt -fno-strip \
    -femit-bin="$out/frame-rv32.elf" \
    --dep core --dep canvas -Mroot=tools/probes/animation.zig \
    --dep canvas -Mcore=src/root.zig \
    --dep surface -Mcanvas=src/graphics/canvas.zig -Msurface=src/graphics/surface.zig
"$zig" build-exe -target riscv32-freestanding-none -mcpu=generic_rv32+m+a+c+zicsr+zifencei \
    -O ReleaseSafe -fentry=nih_scheme_frame -fcompiler-rt -fno-strip \
    -femit-bin="$out/scheme-rv32.elf" \
    --dep scheme_runtime -Mroot=tools/probes/xy_app_scheme.zig \
    --dep view_config -Mscheme_runtime=src/xy/scheme_runtime.zig -Mview_config=src/xy/view_config.zig
python3 - "$out/frame-rv32.elf" "$out/scheme-rv32.elf" <<'PY'
from pathlib import Path
import struct
import sys
for path, entry in zip(sys.argv[1:], (b'nih_animation_frame\x00', b'nih_scheme_frame\x00')):
    data = Path(path).read_bytes()
    assert data[:6] == b'\x7fELF\x01\x01'
    assert struct.unpack_from('<H', data, 18)[0] == 243
    assert struct.unpack_from('<I', data, 24)[0] != 0
    assert struct.unpack_from('<I', data, 36)[0] & 6 == 0  # soft-float ABI
    assert entry in data
print('Animation/Canvas and Scheme callback RV32 soft-float standalone links passed; no device execution')
PY
