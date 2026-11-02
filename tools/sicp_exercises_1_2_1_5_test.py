#!/usr/bin/env python3
"""Validate provenance and the exact exercise 1.2 translation oracle."""
from fractions import Fraction
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import sicp_exercises_1_2_1_5 as exercises


class ExerciseSourceTests(unittest.TestCase):
    def test_original_definitions_and_arithmetic_oracle(self):
        ex14, ex15 = exercises.sources()
        self.assertIn('((if (> b 0) + -) a b)', ex14)
        self.assertIn('(define (p) (p))', ex15)
        self.assertEqual((Fraction(5) + 4 + (2 - (3 - (6 + Fraction(4, 5))))) / (3 * (6 - 2) * (2 - 7)), Fraction(-37, 150))

    def test_corrupt_xml_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            corrupted = Path(directory) / 'xml.tar.gz'
            raw = exercises.inventory.ARCHIVE.read_bytes()
            corrupted.write_bytes(raw[:-1] + bytes([raw[-1] ^ 1]))
            with mock.patch.object(exercises.inventory, 'ARCHIVE', corrupted):
                with self.assertRaisesRegex(ValueError, 'XML archive hash mismatch'):
                    exercises.sources()


if __name__ == '__main__':
    unittest.main()
