#!/usr/bin/env python3
"""Generate standard JIS X 0208 row/cell to Unicode facts using Python's codec."""
from pathlib import Path
import hashlib,json,struct
root=Path(__file__).resolve().parents[1]
data=bytearray();mapped=0
for row in range(0x21,0x7f):
    for cell in range(0x21,0x7f):
        try:
            value=(b'\x1b$B'+bytes((row,cell))+b'\x1b(B').decode('iso2022_jp')
            code=ord(value) if len(value)==1 else 0
        except UnicodeDecodeError:code=0
        if code:mapped+=1
        assert code<=0xffff
        data+=struct.pack('<H',code)
p=root/'src/card/jis0208.bin';p.write_bytes(data)
p.with_suffix('.json').write_text(json.dumps({'encoding':'JIS X 0208','generator':'Python iso2022_jp codec, 94x94 row/cell enumeration','mapped':mapped,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()},indent=2)+'\n')
print(f'{mapped} JIS mappings, {len(data)} bytes')
