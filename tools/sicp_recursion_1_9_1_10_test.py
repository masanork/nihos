#!/usr/bin/env python3
"""Check the provenance and separation of original recursion examples."""
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import sicp_recursion_1_9_1_10 as exercises


class SourceTests(unittest.TestCase):
    def test_distinct_original_additions_and_ackermann(self):
        setup, recursive, iterative, a_proc, wrappers = exercises.sources()
        self.assertIn('(define (inc x)', setup)
        self.assertIn('(inc (+ (dec a) b))', recursive)
        self.assertIn('(+ (dec a) (inc b))', iterative)
        self.assertIn('(A x (- y 1))', a_proc)
        self.assertIn('(define (h n) (A 2 n))', wrappers)

    def test_corrupt_official_code_archive_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'allcode.tar.gz'
            data = exercises.official.ARCHIVE.read_bytes()
            path.write_bytes(data[:-1] + bytes([data[-1] ^ 1]))
            with mock.patch.object(exercises.official, 'ARCHIVE', path):
                with self.assertRaisesRegex(ValueError, 'archive hash mismatch'):
                    exercises.sources()


if __name__ == '__main__':
    unittest.main()
