#!/usr/bin/env python3
"""Count allocated ELF32 sections; no firmware or stack claim."""
from pathlib import Path
import struct
def sections(path):
    data = path.read_bytes()
    if data[:6] != b'\x7fELF\x01\x01':
        raise ValueError('expected little-endian ELF32')
    hdr = struct.unpack_from('<16sHHIIIIIHHHHHH', data)
    shoff, entsize, count, strings = hdr[6], hdr[11], hdr[12], hdr[13]
    entries = [struct.unpack_from('<IIIIIIIIII', data, shoff + i * entsize) for i in range(count)]
    _ = strings
    result = {'executable_bytes': 0, 'readonly_bytes': 0, 'writable_bytes': 0, 'nobits_bytes': 0}
    for entry in entries:
        _, typ, flags, _, _, length, _, _, _, _ = entry
        if not flags & 2:  # SHF_ALLOC
            continue
        if typ == 8:
            result['nobits_bytes'] += length
        elif flags & 4:
            result['executable_bytes'] += length
        elif flags & 1:
            result['writable_bytes'] += length
        else:
            result['readonly_bytes'] += length
    return result


if __name__ == "__main__":
    import json
    import sys
    print(json.dumps(sections(Path(sys.argv[1])), indent=2))
