#!/usr/bin/env python3
"""Run a deterministic RV32 input-to-frame fixture; no physical device."""
import hashlib
import json
from pathlib import Path
from canvas_live import Guest, OUT


def color(raw):
    return raw[64 * 1440 + 48 * 2:64 * 1440 + 48 * 2 + 2].hex()


def main():
    result = OUT / 'smoke.json'
    result.unlink(missing_ok=True)
    guest = Guest()
    try:
        initial = guest.state.copy()
        if color(guest.raw) != 'ffff': raise AssertionError('initial pixel')
        down = guest.sample(1, 200, 100, 1000)
        if down['kind'] != 1 or down['clicks'] != 0 or down['pixel_sha256'] != initial['pixel_sha256']:
            raise AssertionError('press must not click')
        up = guest.sample(0, 200, 100, 2000)
        if up['kind'] != 3 or up['clicks'] != 1 or color(guest.raw) != 'e007':
            raise AssertionError('release must toggle indicator')
        guest.sample(1, 200, 100, 3000)
        cancel = guest.sample(2, 200, 100, 4000)
        release = guest.sample(0, 200, 100, 5000)
        if cancel['kind'] != 4 or release['clicks'] != 1 or release['pixel_sha256'] != up['pixel_sha256']:
            raise AssertionError('multi-contact must cancel click')
        guest.sample(1, 200, 100, 6000)
        drag = guest.sample(1, 300, 100, 7000)
        release2 = guest.sample(0, 300, 100, 8000)
        if drag['kind'] != 2 or release2['clicks'] != 1 or release2['pixel_sha256'] != up['pixel_sha256']:
            raise AssertionError('drag must cancel click')
        receipt = {'evidence': 'esp-emu-rv32-input-fixture', 'initial': initial, 'release': up,
                   'multi_contact_cancel': cancel, 'drag': drag, 'final': release2,
                   'image_sha256': hashlib.sha256((OUT / 'nihos-native.bin').read_bytes()).hexdigest(),
                   'scope': 'debugger input mailbox and offscreen framebuffer; no panel, DMA or real input controller'}
        result.write_text(json.dumps(receipt, indent=2) + '\n')
        print('RV32 input-to-frame smoke passed: press/release, multi-contact, drag')
    finally:
        guest.close()


if __name__ == '__main__': main()
