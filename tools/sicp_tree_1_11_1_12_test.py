#!/usr/bin/env python3
"""Verify source provenance and independent tree-recursion oracles."""
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import sicp_tree_1_11_1_12 as exercises


class TreeSourcesTests(unittest.TestCase):
    def test_sources_and_oracles(self):
        recursive, iterative, coins = exercises.sources()
        self.assertIn('(fib (- n 2))', recursive)
        self.assertIn('(fib-iter 1 0 n)', iterative)
        self.assertIn('(define (count-change amount)', coins)
        self.assertEqual(exercises.fib(46), 1836311903)
        self.assertEqual(exercises.recurrence(10), 1892)
        self.assertEqual(exercises.changes(100), 292)

    def test_corrupt_archive_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'allcode.tar.gz'
            raw = exercises.official.ARCHIVE.read_bytes()
            path.write_bytes(raw[:-1] + bytes([raw[-1] ^ 1]))
            with mock.patch.object(exercises.official, 'ARCHIVE', path):
                with self.assertRaisesRegex(ValueError, 'archive hash mismatch'):
                    exercises.sources()


if __name__ == '__main__':
    unittest.main()
