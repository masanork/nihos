import struct
import unittest
import zlib
import canvas_frame as frame


class FrameTest(unittest.TestCase):
    def test_rgb565_colors(self):
        png = frame.png_rgb565(bytes.fromhex('00f8e0071f00ffff'), 4, 1)
        self.assertEqual(png[:8], b'\x89PNG\r\n\x1a\n')
        self.assertEqual(struct.unpack('>II', png[16:24]), (4, 1))
        pos = png.index(b'IDAT')
        n = struct.unpack('>I', png[pos-4:pos])[0]
        self.assertEqual(zlib.decompress(png[pos+4:pos+4+n]), bytes.fromhex('00 ff0000 00ff00 0000ff ffffff'))

    def test_wrong_size_and_fnv(self):
        with self.assertRaises(ValueError):
            frame.png_rgb565(b'\x00', 1, 1)
        self.assertEqual(frame.fnv1a(b'hello'), 0x4f9f2cab)
