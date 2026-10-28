#!/usr/bin/env python3
"""Independent fixed RGB565 pixel reference for stack-bank scratch reuse."""
import hashlib
import json
from pathlib import Path
import struct
import sys


def reference():
    pixels = bytearray(struct.pack('<H', 0x1234) * 128 * 96)
    for y in range(2):
        for x in range(2):
            alpha = (0, 64, 128, 255)[2*y+x]
            channels = [(((0xffff >> shift) & mask)*alpha + ((0x1234 >> shift) & mask)*(255-alpha)+127)//255
                        for shift, mask in ((11, 31), (5, 63), (0, 31))]
            pixel = (channels[0] << 11) | (channels[1] << 5) | channels[2]
            struct.pack_into('<H', pixels, ((y+4)*128+x+3)*2, pixel)
    value = 2166136261
    for byte in pixels:
        value = ((value ^ byte)*16777619) & 0xffffffff
    return dict(width=128, height=96, stride=256, bytes=len(pixels), pixel_hash=value,
                pixels_sha256=hashlib.sha256(pixels).hexdigest()), pixels


def main():
    out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
    metadata, pixels = reference()
    result = dict(schema=1, evidence='independent host pixels, not native display', **metadata,
                  source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    (out/'scratch.rgb565').write_bytes(pixels)
    (out/'reference.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(metadata))


if __name__ == '__main__':
    main()
