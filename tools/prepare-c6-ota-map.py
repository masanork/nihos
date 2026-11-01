#!/usr/bin/env python3
"""Stage a digest-pinned C6 app as read-only data; never access a device."""
import hashlib
from pathlib import Path
import re
import struct
import sys

src, expected, output = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
if not re.fullmatch(r'[0-9a-f]{64}', expected):
    raise SystemExit('expected a lowercase reviewed SHA-256')
data = src.read_bytes()
if not 36 <= len(data) <= 1536 * 1024 or data[0] != 0xe9 or struct.unpack_from('<H', data, 12)[0] != 13 or struct.unpack_from('<I', data, 32)[0] != 0xabcd5432:
    raise SystemExit('not a bounded C6 application image')
if hashlib.sha256(data).hexdigest() != expected:
    raise SystemExit('candidate SHA-256 mismatch')
(output / 'candidate.bin').write_bytes(data)
(output / 'ota-image.S').write_text('''.section .flash.c6_image,"a",@progbits
.balign 4
.global nih_c6_candidate_start
.global nih_c6_candidate_end
nih_c6_candidate_start:
.incbin "candidate.bin"
nih_c6_candidate_end:
''')
