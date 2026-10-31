#!/bin/sh
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
zig=$(sh tools/bootstrap-zig.sh)
out="$repo_root/build/xy-animation"
mkdir -p "$out"
"$zig" test src/app/animation.zig -O ReleaseSafe
"$zig" test src/app/plot_app.zig -O ReleaseSafe
cc -std=c11 -Wall -Wextra -Werror -I include -fsyntax-only tools/probes/app_protocol.c
"$zig" build-exe -target riscv32-freestanding-none -mcpu=generic_rv32+m+a+c+zicsr+zifencei \
    -O ReleaseSafe -fentry=nih_animation_frame -fcompiler-rt -fno-strip \
    -femit-bin="$out/frame-rv32.elf" \
    --dep core --dep canvas -Mroot=tools/probes/animation.zig \
    --dep canvas -Mcore=src/root.zig \
    --dep surface -Mcanvas=src/graphics/canvas.zig -Msurface=src/graphics/surface.zig
python3 - "$out/frame-rv32.elf" <<'PY'
from pathlib import Path
import struct
import sys
data = Path(sys.argv[1]).read_bytes()
assert data[:6] == b'\x7fELF\x01\x01'
assert struct.unpack_from('<H', data, 18)[0] == 243
assert struct.unpack_from('<I', data, 24)[0] != 0
assert struct.unpack_from('<I', data, 36)[0] & 6 == 0  # soft-float ABI
assert b'nih_animation_frame\x00' in data
print('Pure animation/Canvas RV32 soft-float standalone link passed; no device execution')
PY
