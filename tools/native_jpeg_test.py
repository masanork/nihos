import hashlib
import json
from pathlib import Path
import unittest
from native_jpeg import fnv, parse


def trace():
    data = b'\xff\xd8' + bytes(640) + b'\xff\xd9'
    lines = []
    for kind in (0, 1):
        lines.append(f'NIHOS_JPEG_BEGIN kind={kind:08x} bytes={len(data):08x} width=00000500 height=000002d0 quality=0000004b source_fnv=00000001 encode_us=00004e20')
        for offset in range(0, len(data), 96):
            lines.append(f'NIHOS_JPEG_DATA kind={kind:08x} offset={offset:08x} data={data[offset:offset+96].hex()}')
        lines.append(f'NIHOS_JPEG_END kind={kind:08x} bytes={len(data):08x} fnv={fnv(data):08x}')
    lines.append('NIHOS_JPEG_DONE')
    return lines


class JpegCaptureTests(unittest.TestCase):
    def test_retained_hardware_pattern_identity_and_geometry(self):
        directory = Path(__file__).resolve().parents[1] / 'docs/measurements/evidence/2026-10-31-camera-jpeg'
        summary = json.loads((directory / 'summary.json').read_text())
        data = (directory / 'pattern.jpg').read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        self.assertEqual(digest, summary['public_pattern']['sha256'])
        for trial in summary['trials']:
            self.assertEqual(digest, trial['images']['pattern.jpg']['sha256'])
        self.assertTrue(data.startswith(b'\xff\xd8') and data.endswith(b'\xff\xd9'))
        position, found = 2, False
        while data[position:position+2] != b'\xff\xda':
            length = int.from_bytes(data[position+2:position+4], 'big')
            self.assertGreaterEqual(length, 2)
            if data[position:position+2] == b'\xff\xc0':
                payload = data[position+4:position+2+length]
                self.assertEqual(payload[:6], bytes.fromhex('0802d0050003'))
                self.assertEqual(payload[6:9], bytes.fromhex('012100'))
                found = True
            position += length + 2
            self.assertLess(position, len(data))
        self.assertTrue(found)

    def test_complete_integrity_protocol(self):
        records, images = parse('\n'.join(trace()))
        self.assertEqual(set(records), {0, 1})
        self.assertEqual(len(images[0]), 644)

    def test_rejects_corruption_missing_bytes_wrong_geometry_and_timing(self):
        for old, new in [('offset=00000060', 'offset=00000061'), ('width=00000500', 'width=00000280'),
                         ('quality=0000004b', 'quality=00000000'), ('encode_us=00004e20', 'encode_us=ffffffff'),
                         ('source_fnv=00000001 ', ''), ('data=ffd8', 'data=ffd9')]:
            with self.subTest(old=old), self.assertRaises(ValueError):
                parse('\n'.join(trace()).replace(old, new, 1))

    def test_rejects_truncation_duplicate_end_and_firmware_failure(self):
        lines = trace()
        with self.assertRaises(ValueError):
            parse('\n'.join(lines[:-1]))
        end = next(line for line in lines if 'JPEG_END' in line)
        for extra in (end, 'NIHOS_JPEG_FAIL stage=00000006 code=00000002'):
            with self.assertRaises(ValueError):
                parse('\n'.join(lines[:-1] + [extra, lines[-1]]))


if __name__ == '__main__':
    unittest.main()
