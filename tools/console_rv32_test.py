import unittest
from console_rv32 import FRAME_BYTES, check_frame
from console_reference import reference


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

    def test_independent_reference_and_negative_control(self):
        for font in ('basic-light', 'jetbrains', 'source-code'):
            frame = reference(font)
            self.assertEqual(len(frame), FRAME_BYTES)
            self.assertEqual(frame[:2], bytes((0x82, 0x10)))
            changed = bytearray(frame)
            changed[len(frame) // 2] ^= 1
            with self.assertRaises(ValueError):
                check_frame(bytes(changed), frame, 'independent pixel reference')
        with self.assertRaises(ValueError):
            reference('unknown')
