#!/usr/bin/env python3
import tempfile
from pathlib import Path
import unittest
from unittest import mock
import sicp_rational_2_1 as exercises

class SourceTests(unittest.TestCase):
    def test_source_and_sign_cases(self):
        exercises.verify_sources()
        self.assertIn((6, -8), exercises.INPUTS)
        self.assertIn((-6, -8), exercises.INPUTS)
        self.assertIn('(let* ', exercises.CANDIDATE)

    def test_corrupt_archive_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder) / 'bad.tar.gz'
            p.write_bytes(exercises.official.ARCHIVE.read_bytes() + b'bad')
            with mock.patch.object(exercises.official, 'ARCHIVE', p):
                with self.assertRaisesRegex(ValueError, 'archive hash'): exercises.verify_sources()

if __name__ == '__main__': unittest.main()
