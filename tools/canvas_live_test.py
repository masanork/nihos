import struct
import tempfile
from pathlib import Path
import unittest
from canvas_live import Guest, encode_frame, acquire_session_lock, check_guard, validate_document
from canvas_frame import FRAME_BYTES


class FakeMi:
    def __init__(self): self.writes = []; self.resumes = 0
    def write(self, address, data): self.writes.append((address, data))
    def resume_to_frame(self): self.resumes += 1


class InputTest(unittest.TestCase):
    def setUp(self):
        self.g = Guest.__new__(Guest)
        self.g.input_addr = 100
        self.g.document_addr = 200
        self.g.last_time = 10
        self.g.mi = FakeMi()
        self.g.state = {'ok': True}
        self.g.refresh = lambda: None

    def test_valid_sample_is_packed_and_resumed(self):
        self.assertEqual(self.g.sample(1, 200, 100, 20), {'ok': True})
        self.assertEqual(self.g.mi.writes, [(100, struct.pack('<IIIII', 1, 1, 200, 100, 20))])
        self.assertEqual(self.g.mi.resumes, 1)

    def test_editor_and_key_commands_validate_and_pack_hid(self):
        self.g.start_editor()
        self.assertEqual(self.g.mi.writes[-1], (100, struct.pack('<IIIII', 3, 0, 0, 0, 0)))
        self.g.state = {'mode': 1}
        self.g.key(2, 0x37)
        self.assertEqual(self.g.mi.writes[-1], (100, struct.pack('<IIIII', 2, 2, 0x37, 0, 0)))
        self.assertEqual(self.g.mi.resumes, 2)
        for modifiers, usage in ((True, 4), (0, 0), (256, 4), (0, 224), (0, -1)):
            with self.subTest(modifiers=modifiers, usage=usage), self.assertRaises(ValueError):
                self.g.key(modifiers, usage)
        self.g.state = {'mode': 0}
        with self.assertRaises(ValueError):
            self.g.key(0, 4)
        self.assertEqual(len(self.g.mi.writes), 2)

    def test_document_load_validates_before_guest_write(self):
        self.g.state = {'mode': 1, 'text': 'xy  '}
        self.g.load_document('xy  ')
        self.assertEqual(self.g.mi.writes, [(200, struct.pack('<I80s', 4, b'xy  ')),
                                            (100, struct.pack('<IIIII', 4, 0, 0, 0, 0))])
        for text in ('x\n', '日本語', 'a' * 81, None, 123):
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.g.load_document(text)
        self.assertEqual(len(self.g.mi.writes), 2)
        self.g.state = {'mode': 0}
        with self.assertRaises(ValueError):
            self.g.load_document('valid')

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


class GuardTest(unittest.TestCase):
    def test_changed_or_short_guard_is_rejected(self):
        check_guard(bytes([0xa5]) * 16)
        for value in (bytes([0xa5]) * 15, bytes([0xa5]) * 15 + b'\x00'):
            with self.subTest(value=value), self.assertRaises(RuntimeError):
                check_guard(value)


class LockTest(unittest.TestCase):
    def test_only_one_session_can_own_the_worktree(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'session.lock'
            first = acquire_session_lock(path)
            try:
                with self.assertRaises(RuntimeError):
                    acquire_session_lock(path)
            finally:
                first.close()
            second = acquire_session_lock(path)
            second.close()
