#!/usr/bin/env python3
"""Actual RV32 xy Document/input/raster on ESP-EMU; no panel or physical input."""
import hashlib
import io
import json
from pathlib import Path
import struct
from PIL import Image
from canvas_live import Guest, OUT, ROOT
from canvas_frame import png_rgb565


def main():
    output = ROOT / 'build/xy-scratch-smoke'
    output.mkdir(parents=True, exist_ok=True)
    (output / 'report.json').unlink(missing_ok=True)
    paths = sorted(p for p in (ROOT / 'src').rglob('*') if p.suffix in ('.zig', '.c', '.h', '.S', '.ld'))
    paths += [ROOT / p for p in ('tools/build-native.sh', 'tools/build-native-elf.sh', 'tools/run-xy-scratch-smoke.py')]
    sha = lambda data: hashlib.sha256(data).hexdigest()
    sources = {str(p.relative_to(ROOT)): sha(p.read_bytes()) for p in paths}
    guest = Guest()
    observations = []
    try:
        def read_state(label, pixels=False):
            values = struct.unpack('<8I', guest.mi.read(guest.output_addr, 32))
            length, content = struct.unpack('<I80s', guest.mi.read(guest.document_addr, 84))
            if values[4] != 2 or length > 80:
                raise AssertionError('invalid xy fixture state')
            if guest.mi.read(0x481f2000, 16) != b'\xa5' * 16:
                raise AssertionError('xy fixture touched its framebuffer guard')
            row = {'label': label, 'text': content[:length].decode('utf-8'), 'cursor': values[7], 'keys': values[5], 'edits': values[6]}
            if pixels:
                guest.mi.command('-interpreter-exec console "dump binary memory xy-frame.rgb565 0x48030000 0x481f2000"', timeout=90)
                frame = (OUT / 'xy-frame.rgb565').read_bytes()
                row['pixel_sha256'] = sha(frame)
                image = Image.open(io.BytesIO(png_rgb565(frame, 720, 1280)))
                image.transpose(Image.Transpose.ROTATE_270).save(output / (label + '.png'))
            observations.append(row)
            return row

        def command(number, value=0, modifiers=0):
            guest.mi.write(guest.input_addr, struct.pack('<5I', number, modifiers, value, 0, 1000))
            guest.mi.resume_to_frame()

        def serial(data):
            for byte in data:
                command(6, byte)

        command(5)
        initial = read_state('initial', True)
        assert initial['text'] == '' and initial['cursor'] == 0
        serial(b'a\r\nb')
        command(2, 0x50)  # Left
        before = read_state('before-insert', True)
        assert before['text'] == 'a\nb' and before['cursor'] == 2
        command(2, 0x1b)  # x
        assert read_state('inserted')['text'] == 'a\nxb'
        command(2, 0x1d, 1)  # Ctrl-Z
        undone = read_state('undo', True)
        assert undone['text'] == before['text'] and undone['cursor'] == before['cursor']
        assert undone['pixel_sha256'] == before['pixel_sha256']
        serial('葛\U000e0100'.encode())
        assert read_state('ivs')['text'] == 'a\n葛\U000e0100b'
        command(2, 0x2a)  # Backspace removes the whole IVS cluster.
        deleted = read_state('cluster-delete', True)
        assert deleted['text'] == before['text'] and deleted['pixel_sha256'] == before['pixel_sha256']
        command(2, 0x29)  # Esc -> minibuffer
        serial(b'help\r\n')
        help_view = read_state('help', True)
        assert help_view['text'] == before['text'] and help_view['pixel_sha256'] != before['pixel_sha256']
        command(2, 0x29)
        returned = read_state('returned', True)
        assert returned['pixel_sha256'] == before['pixel_sha256']
        serial(b':storage')
        assert read_state('literal-colon')['text'] == 'a\n:storageb'
        scratch = read_state('before-system', True)
        for name in (b'log', b'mem', b'tasks'):
            command(2, 0x29)
            serial(name + b'\r\n')
            first = read_state(name.decode() + '-buffer', True)
            assert first['text'] == scratch['text'] and first['cursor'] == scratch['cursor']
            assert first['pixel_sha256'] != scratch['pixel_sha256']
            for usage, modifiers in ((0x1b, 0), (0x28, 0), (0x2a, 0), (0x1d, 1), (0x07, 1)):
                command(2, usage, modifiers)
            blocked = read_state(name.decode() + '-readonly', True)
            assert blocked['text'] == scratch['text'] and blocked['cursor'] == scratch['cursor']
            assert blocked['pixel_sha256'] == first['pixel_sha256']
            if name == b'log':
                for _ in range(70): command(2, 0x51)
                bottom = read_state('log-bottom', True)
                assert bottom['pixel_sha256'] != first['pixel_sha256']
                for _ in range(5): command(2, 0x51)
                assert read_state('log-clamped', True)['pixel_sha256'] == bottom['pixel_sha256']
            command(2, 0x0f, 1)  # Ctrl-L captures again and resets scroll.
            assert read_state(name.decode() + '-refreshed', True)['pixel_sha256'] == first['pixel_sha256']
            command(2, 0x29)
            returned = read_state(name.decode() + '-return', True)
            assert returned['text'] == scratch['text'] and returned['cursor'] == scratch['cursor']
            assert returned['pixel_sha256'] == scratch['pixel_sha256']
        command(2, 0x1d, 1)  # Last scratch edit is still undoable after all views.
        assert read_state('undo-after-system')['text'] == 'a\n:storagb'
        command(5)
        serial(b'Shared Document / live editing.\r\nRAM scratch / UTF-8 document.')
        read_state('workspace', True)
        if any(sha((ROOT / p).read_bytes()) != h for p, h in sources.items()):
            raise RuntimeError('sources changed during xy capture')
        report = {'passed': True, 'evidence': 'ESP-EMU RV32 offscreen workspace fixture',
            'normal_boot_executed': False, 'physical_device_used': False, 'panel_or_dma_tested': False,
            'scheme_vm_tested': False, 'persistence_tested': False, 'unicode_raster_tested': False,
            'snapshot_prefix_limit_bytes': 80, 'sources': sources, 'observations': observations,
            'image_sha256': sha((OUT / 'nihos-native.bin').read_bytes()),
            'elf_sha256': sha((OUT / 'nihos-native.elf').read_bytes())}
        (output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print('RV32 xy scratch passed: editing, CRLF, IVS deletion, undo pixels, help return, literal colon and read-only system buffers')
    finally:
        guest.close()


if __name__ == '__main__':
    main()
