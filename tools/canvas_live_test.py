import struct
import unittest
from canvas_live import Guest, encode_frame
from canvas_frame import FRAME_BYTES


class FakeMi:
    def __init__(self): self.writes = []; self.resumes = 0
    def write(self, address, data): self.writes.append((address, data))
    def resume_to_frame(self): self.resumes += 1


class InputTest(unittest.TestCase):
    def setUp(self):
        self.g = Guest.__new__(Guest)
        self.g.input_addr = 100
        self.g.last_time = 10
        self.g.mi = FakeMi()
        self.g.state = {'ok': True}
        self.g.refresh = lambda: None

    def test_valid_sample_is_packed_and_resumed(self):
        self.assertEqual(self.g.sample(1, 200, 100, 20), {'ok': True})
        self.assertEqual(self.g.mi.writes, [(100, struct.pack('<IIIII', 1, 1, 200, 100, 20))])
        self.assertEqual(self.g.mi.resumes, 1)

    def test_invalid_input_is_not_written(self):
        for values in ((1, 720, 100, 20), (3, 0, 0, 20), (1, 0, 1280, 20),
                       (1, 0, 0, 9), (True, 0, 0, 20), (1, 0, 0, 0x100000000)):
            with self.subTest(values=values), self.assertRaises(ValueError):
                self.g.sample(*values)
        self.assertEqual(self.g.mi.writes, [])


class FrameCacheTest(unittest.TestCase):
    def test_reuse_and_changed_pixels(self):
        raw = bytes(FRAME_BYTES)
        digest, png = encode_frame(raw)
        digest2, reused = encode_frame(raw, digest, png)
        self.assertEqual(digest2, digest)
        self.assertIs(reused, png)
        changed = b'\x01' + raw[1:]
        digest3, png3 = encode_frame(changed, digest, png)
        self.assertNotEqual(digest3, digest)
        self.assertNotEqual(png3, png)
        with self.assertRaises(RuntimeError):
            encode_frame(raw[:-1])
