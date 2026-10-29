import unittest
from splash_reference import reference
from splash_rv32 import verify


class SplashRv32Test(unittest.TestCase):
    def test_reference_and_negative_controls(self):
        for layout in ('portrait', 'landscape'):
            for progress in (0, 255):
                frame = reference(layout, progress)
                verify(frame, frame)
                changed = bytearray(frame)
                changed[len(frame) // 2] ^= 1
                with self.assertRaises(ValueError):
                    verify(bytes(changed), frame)
                with self.assertRaises(ValueError):
                    verify(frame[:-1], frame)
        with self.assertRaises(ValueError):
            reference('unknown', 0)
