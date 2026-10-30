import unittest
from splash_reference import reference
from splash_rv32 import verify


class SplashRv32Test(unittest.TestCase):
    def test_reference_and_negative_controls(self):
        for layout in ('portrait', 'landscape'):
            for progress, status in ((0, 5), (128, 5), (255, 5), (128, 6), (128, 7)):
                frame = reference(layout, progress, status)
                verify(frame, frame)
                changed = bytearray(frame)
                changed[len(frame) // 2] ^= 1
                with self.assertRaises(ValueError):
                    verify(bytes(changed), frame)
                with self.assertRaises(ValueError):
                    verify(frame[:-1], frame)
        with self.assertRaises(ValueError):
            reference('unknown', 0)
