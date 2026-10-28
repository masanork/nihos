#!/usr/bin/env python3
"""Keep the C++/newlib namespace private; kernel helpers must remain SRAM code."""
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(sys.argv[1]).resolve()
CXX = sys.argv[2]
PREFIX = CXX.removesuffix("g++")
sha = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()
raw = OUT / "graphics/build/font-link-oracle"
data = raw.read_bytes()
assert data[:6] == b"\x7fELF\x01\x01" and struct.unpack_from("<HH", data, 16) == (1, 243)
off = struct.unpack_from("<I", data, 32)[0]
step, count = struct.unpack_from("<HH", data, 46)
sections = [struct.unpack_from("<10I", data, off + i * step) for i in range(count)]
keep = {"graphics_font_link_probe", "graphics_result", "graphics_execution_pc", "graphics_output"}
renames = {}
for s in sections:
    if s[1] != 2:
        continue
    strings = sections[s[6]]
    names = data[strings[4]:strings[4] + strings[5]]
    for pos in range(s[4], s[4] + s[5], 16):
        name, _, _, info, _, index = struct.unpack_from("<IIIBBH", data, pos)
        if info >> 4 not in (1, 2) or info & 15 not in (1, 2) or index == 0:
            continue
        name = names[name:].split(b"\0", 1)[0].decode()
        if name and name not in keep:
            renames[name] = "nih_gfx_" + name
mapping = OUT / "graphics/private-symbols.txt"
mapping.write_text("".join(f"{a} {b}\n" for a, b in sorted(renames.items())))
payload = OUT / "graphics_payload.o"
subprocess.run([PREFIX + "objcopy", "--remove-section=.eh_frame", "--remove-section=.eh_frame_hdr",
                "--redefine-syms=" + str(mapping), str(raw), str(payload)], check=True)
# No unprefixed libc/compiler helper may bind a kernel call into Flash.
defined = subprocess.check_output([PREFIX + "nm", "-g", "--defined-only", str(payload)], text=True)
assert not any(line.split()[-1] in {"malloc", "free", "memcpy", "memmove", "memset", "memcmp", "__udivdi3", "__getreent"} for line in defined.splitlines())
fonts = ROOT / "build/graphics-probe/sources"
assembly = ['.section .graphics.fonts,"a",@progbits\n.balign 16\n']
inputs = []
for family, filename in [("gothic", "BIZUDGothic-Regular.ttf"), ("mincho", "BIZUDMincho-Regular.ttf")]:
    p = fonts / filename
    assembly.append(f'.global nih_graphics_{family}_start\nnih_graphics_{family}_start:\n.incbin {json.dumps(str(p))}\n.global nih_graphics_{family}_end\nnih_graphics_{family}_end:\n.balign 16\n')
    inputs.append({"family": family, "name": filename, "bytes": p.stat().st_size, "sha256": sha(p)})
asm = OUT / "graphics/fonts.S"
asm.write_text("".join(assembly))
subprocess.run([PREFIX + "gcc", "-c", "-march=rv32imac_zicsr_zifencei", "-mabi=ilp32", str(asm), "-o", str(OUT / "graphics_fonts.o")], check=True)
spec = importlib.util.spec_from_file_location("native_manifest", ROOT / "tools/native-sqlite-manifest.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
result = {"schema": 1, "scope": "native graphics fixture with immutable Flash font inputs, not a runtime font filesystem",
          "payload_sha256": sha(payload), "fonts_object_sha256": sha(OUT / "graphics_fonts.o"),
          "allowed_functions": module.functions(payload), "renamed_symbols": renames,
          "fonts": inputs, "compiler": subprocess.check_output([CXX, "--version"], text=True).splitlines()[0],
          "source_sha256": {str(p.relative_to(ROOT)): sha(p) for p in sorted((ROOT / "probes/graphics").rglob("*")) if p.is_file() and "__pycache__" not in p.parts}}
(OUT / "graphics-manifest.json").write_text(json.dumps(result, indent=2) + "\n")
print(payload)
