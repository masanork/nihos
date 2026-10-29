#!/usr/bin/env python3
"""Negative controls for the isolated normal-device study image auditor."""
import importlib.util
from pathlib import Path
import struct
import sys


def load(path):
    spec = importlib.util.spec_from_file_location('study_native_image', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main(auditor, elf_path, image_path):
    audit = load(auditor)
    elf, image = Path(elf_path).read_bytes(), Path(image_path).read_bytes()
    audit.audit(elf, image, 'integer', 'device')
    def rejected(changed_elf, changed_image, label):
        try: audit.audit(changed_elf, changed_image, 'integer', 'device')
        except ValueError as error:
            print(label + ': rejected: ' + str(error)); return
        raise ValueError(label + ' unexpectedly passed')
    for old, new, label in ((b'nih_mlkem_alloc\0', b'nih_mlkem_allox\0', 'unknown function'), (b'__native_pqc_xip\0', b'__native_pqc_xiy\0', 'missing profile marker')):
        if len(old) != len(new) or old not in elf: raise ValueError('mutation target missing')
        rejected(elf.replace(old, new), image, label)
    h = struct.unpack_from('<HHIIIIIHHHHHH', elf, 16)
    sections = [struct.unpack_from('<10I', elf, h[5] + i * h[10]) for i in range(h[11])]
    shstr = sections[h[12]]
    names = elf[shstr[4]:shstr[4] + shstr[5]]
    ro_index = next(i for i, s in enumerate(sections) if names[s[0]:names.index(0, s[0])] == b'.flash.pqc.rodata')
    changed = bytearray(elf)
    struct.pack_into('<I', changed, h[5] + ro_index * h[10] + 8, 6)
    rejected(bytes(changed), image, 'executable read-only section')
    code = next(s for s in sections if names[s[0]:names.index(0, s[0])] == b'.flash.pqc')
    payload = elf[code[4]:code[4] + code[5]]
    offset = image.find(payload)
    if offset < 0 or image.find(payload, offset + 1) >= 0: raise ValueError('image payload not uniquely found')
    changed_image = bytearray(image)
    changed_image[offset + len(payload)//2] ^= 1
    rejected(elf, bytes(changed_image), 'changed Flash image byte')


if __name__ == '__main__':
    if len(sys.argv) != 4: raise SystemExit('usage: audit_combined_xip_negative.py STUDY_AUDITOR ELF IMAGE')
    main(*sys.argv[1:])
