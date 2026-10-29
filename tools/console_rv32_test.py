import unittest
from console_rv32 import FRAME_BYTES, check_frame


class ConsoleRv32Test(unittest.TestCase):
    def test_reject_changed_and_truncated_frames(self):
        frame = bytes(FRAME_BYTES)
        check_frame(frame, frame)
        changed = bytearray(frame)
        changed[FRAME_BYTES // 2] = 1
        with self.assertRaises(ValueError):
            check_frame(bytes(changed), frame)
        with self.assertRaises(ValueError):
            check_frame(frame[:-1], frame)
