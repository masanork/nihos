import hashlib
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools/console'))
import font_rle


class ConsoleFontRleTest(unittest.TestCase):
    def test_run_boundaries_and_truncation(self):
        for count in (1, 15, 16, 17, 270, 271, 272, 450):
            for alpha in (0, 1, 15):
                pixels = bytes([alpha]) * count
                self.assertEqual(font_rle.decode(font_rle.encode(pixels)), pixels)
        with self.assertRaises(ValueError):
            font_rle.decode(b'\x0f')

    def test_assets_match_original_coverage(self):
        expected = {
            'jetbrains': 'd32bf7b3f187d7729f27ea5df5565429b27e2d9a44908765e7c1df552dcacd95',
            'source_code': 'f159bacb00a3a4da2e73996098164911e86339fc4955a033b5c7a96c4eddaa2b',
        }
        for name, digest in expected.items():
            root = ROOT / 'src/graphics/ascii'
            source = (root / (name + '.zig')).read_text()
            entries = [tuple(map(int, item)) for item in re.findall(r'offset = (\d+), \.length = (\d+)', source)]
            data = (root / (name + '.rle')).read_bytes()
            self.assertEqual(len(entries), 95)
            pixels = bytearray()
            next_offset = 0
            for offset, length in entries:
                self.assertEqual(offset, next_offset)
                decoded = font_rle.decode(data[offset:offset + length])
                self.assertEqual(len(decoded), 450)
                pixels.extend(decoded)
                next_offset += length
            self.assertEqual(next_offset, len(data))
            self.assertEqual(hashlib.sha256(pixels).hexdigest(), digest)


if __name__ == '__main__':
    unittest.main()
