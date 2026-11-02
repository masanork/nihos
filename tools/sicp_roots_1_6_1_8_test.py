#!/usr/bin/env python3
"""Verify source provenance for the original root definitions."""
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import sicp_roots_1_6_1_8 as roots


class RootSourcesTests(unittest.TestCase):
    def test_original_new_if_and_sqrt(self):
        square, original, new_if, replacement = roots.sources()
        self.assertIn('(* x x)', square)
        self.assertIn('(sqrt-iter 1.0 x)', original)
        self.assertIn('(cond (predicate then-clause)', new_if)
        self.assertIn('(sqrt-iter (improve guess x)', replacement)

    def test_corrupt_xml_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'xml.tar.gz'
            data = roots.inventory.ARCHIVE.read_bytes()
            path.write_bytes(data[:-1] + bytes([data[-1] ^ 1]))
            with mock.patch.object(roots.inventory, 'ARCHIVE', path):
                with self.assertRaisesRegex(ValueError, 'XML archive hash mismatch'):
                    roots.sources()


if __name__ == '__main__':
    unittest.main()
