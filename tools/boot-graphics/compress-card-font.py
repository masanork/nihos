#!/usr/bin/env python3
"""Retain the complete pinned font, encoding rows without changing any pixel."""
from pathlib import Path
import hashlib,json,sys
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'tools'))
from font_codec import encode,decode
raw=(ROOT/'src/graphics/card_read_font.bin').read_bytes();encoded=encode(raw)
if decode(encoded)!=raw:raise SystemExit('font round trip failed')
destination=ROOT/'src/graphics/card_auto_font.bin';destination.write_bytes(encoded)
manifest=json.loads((ROOT/'src/graphics/card_read_font.json').read_text())
manifest.update(font_encoding='row12-v1',font_raw_sha256=hashlib.sha256(raw).hexdigest(),font_bytes=len(encoded),font_sha256=hashlib.sha256(encoded).hexdigest())
for n in ('tools/font_codec.py','tools/boot-graphics/compress-card-font.py','src/graphics/card_read_result.zig'):
    manifest['sources'][n]=hashlib.sha256((ROOT/n).read_bytes()).hexdigest()
destination.with_suffix('.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(f'Lossless font: {len(raw)} -> {len(encoded)} bytes')
