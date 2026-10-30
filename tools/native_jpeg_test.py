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
