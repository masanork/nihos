#!/usr/bin/env python3
"""Bake a bounded JIS X 0213 + Latin bitmap font from the pinned OFL font."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
from PIL import Image, ImageDraw, ImageFont
ROOT = Path(__file__).resolve().parents[2]
FONT_SHA = 'd9854c7a8ef170b5a7932558856fd64eb8de0b007cd823fed6f9f514ad2803d3'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('font', type=Path)
    args = parser.parse_args()
    if hashlib.sha256(args.font.read_bytes()).hexdigest() != FONT_SHA:
        parser.error('font differs from pinned Noto Serif CJK JP Regular')
    chars = set(range(32, 256)) | {0x25a1}
    for lead in range(0x81, 0xfd):
        for trail in range(0x40, 0xfd):
            try: text = bytes((lead, trail)).decode('shift_jis_2004')
            except UnicodeDecodeError: continue
            if len(text) == 1: chars.add(ord(text))
    font = ImageFont.truetype(str(args.font), 14)
    data = bytearray()
    for code in sorted(chars):
        image = Image.new('1', (16, 16))
        box = font.getbbox(chr(code))
        x0,y0,x1,y1 = box
        ImageDraw.Draw(image).text(((16-x1+x0)//2-x0, (16-y1+y0)//2-y0), chr(code), font=font, fill=1)
        data += struct.pack('<I',code) + image.tobytes()
    destination = ROOT / 'src/graphics/card_read_font.bin'
    destination.write_bytes(data)
    sources = ('tools/boot-graphics/generate-card-read-font.py', 'src/platform/native/card_read.zig', 'src/platform/native/keypad_display.zig', 'src/platform/native/usb_probe.zig', 'src/platform/native/display_runtime.zig', 'src/graphics/card_pin.zig', 'src/board/tab5/native_scanout.c', 'src/board/tab5/keypad_sparse.h', 'src/board/tab5/notice_sparse.h', 'src/board/tab5/scanout_retire.h')
    manifest = {'schema':1, 'ui_mode':'runtime', 'scene_handoff':'dma-eof-panel-held-v1', 'font_bytes':len(data), 'font_sha256':hashlib.sha256(data).hexdigest(),
                'font_source_sha256':FONT_SHA, 'glyphs':len(chars),
                'allowed_functions':['card_read.prepare', 'card_read.run', 'card_read.redraw', 'keypad_display.prepare', 'keypad_display.stage', 'keypad_display.bind', 'keypad_display.paintTextures', 'usb_probe.Device.send', 'usb_probe.Device.scrub', 'usb_probe.Device.powerCut', 'display_runtime.start', 'display_runtime.replaceCard'],
                'sources':{name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in sources}}
    destination.with_suffix('.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(f'{len(chars)} glyphs, {len(data)} bytes')
if __name__ == '__main__': main()
