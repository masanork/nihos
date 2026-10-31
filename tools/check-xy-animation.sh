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
    # Both consumers must reference the declared table storage by address.
    # Array-value indexing can create an anonymous .rodata copy instead.
    header = struct.unpack_from('<HHIIIIIHHHHHH', data, 16)
    sections = [struct.unpack_from('<10I', data, header[5] + i * header[10])
                for i in range(header[11])]
    names_section = sections[header[12]]
    names = data[names_section[4]:names_section[4] + names_section[5]]
    def name_at(table, offset):
        return table[offset:table.index(0, offset)].decode('ascii')
    tables = []
    for section in sections:
        if section[1] != 2:  # SHT_SYMTAB
            continue
        strings_section = sections[section[6]]
        strings = data[strings_section[4]:strings_section[4] + strings_section[5]]
        for offset in range(section[4], section[4] + section[5], section[9]):
            name, value, size, _, _, index = struct.unpack_from('<IIIBBH', data, offset)
            if name_at(strings, name).endswith('plot_config.sine'):
                storage = sections[index]
                assert size == 512 and value % 2 == 0
                assert name_at(names, storage[0]) == '.flash.xyrodata'
                assert storage[2] & 7 == 2  # allocated, readonly, non-executable
                tables.append((value, size))
    assert len(tables) == 1, 'missing or competing declared sine table storage'
print('Animation/Canvas and Scheme callback RV32 soft-float standalone links passed; no device execution')
PY
