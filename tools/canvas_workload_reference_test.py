import unittest
import canvas_workload_reference as ref


class ReferenceTest(unittest.TestCase):
    def test_named_examples_and_negative_control(self):
        self.assertEqual(ref.editor_pixel(0, 199), 0x1082)
        self.assertEqual(ref.editor_pixel(30, 40), 0x07ff)
        self.assertEqual(ref.editor_pixel(15, 15), 0xffff)
        self.assertEqual(ref.editor_pixel(10, 20), 0xf800)
        self.assertEqual(ref.editor_pixel(270, 20), 0x001f)
        self.assertEqual(ref.editor_pixel(50, 55), 0x07e0)
        self.assertEqual(ref.editor_pixel(280, 30), 0xffe0)
        self.assertEqual(ref.editor_pixel(10, 160), 0xffe0)
        self.assertNotEqual(ref.editor_pixel(9, 20), 0xf800)
        self.assertNotEqual(ref.editor_pixel(270, 182), 0x001f)
        self.assertEqual(ref.indexed_pixel(0, 0), 0x5a5a)
        self.assertEqual(ref.indexed_pixel(1, 1), 0x5a5a)
        self.assertEqual(ref.indexed_pixel(2, 0), (3 * 257) ^ 0x5a5a)
        frame = ref.reference('scroll')
        ref.verify('scroll', frame)
        with self.assertRaisesRegex(ValueError, 'byte 42'):
            ref.verify('scroll', frame[:42] + bytes([frame[42] ^ 1]) + frame[43:])
        with self.assertRaises(ValueError): ref.verify('scroll', frame[:-1])
