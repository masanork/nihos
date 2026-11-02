#!/usr/bin/env python3
import tempfile
from pathlib import Path
import unittest
from unittest import mock
import sicp_lists_2_17_2_21 as suite

class Sources(unittest.TestCase):
    def test_original_examples_and_cases(self):
        suite.verify_sources()
        self.assertEqual({x[0] for x in suite.CASES}, {'2.17', '2.18', '2.21'})
        self.assertIn('square-map', {x[1] for x in suite.CASES})

    def test_corrupt_archive_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'bad.tar.gz'; p.write_bytes(suite.official.ARCHIVE.read_bytes()+b'bad')
            with mock.patch.object(suite.official, 'ARCHIVE', p):
                with self.assertRaisesRegex(ValueError, 'archive hash'): suite.verify_sources()

if __name__ == '__main__': unittest.main()
