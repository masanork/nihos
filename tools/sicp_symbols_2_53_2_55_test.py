#!/usr/bin/env python3
import tempfile
from pathlib import Path
import unittest
from unittest import mock
import sicp_symbols_2_53_2_55 as suite

class SourceTests(unittest.TestCase):
    def test_original_examples_and_candidates(self):
        suite.verify_sources()
        self.assertEqual({case[0] for case in suite.CASES}, {'2.53', '2.54', '2.55'})
        self.assertEqual(sum(case[0] == '2.53' and not case[1] for case in suite.CASES), 7)
        self.assertTrue(any(case[0] == '2.54' and case[1] for case in suite.CASES))
    def test_archive_corruption_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'bad.tar.gz';path.write_bytes(suite.official.ARCHIVE.read_bytes()+b'bad')
            with mock.patch.object(suite.official,'ARCHIVE',path):
                with self.assertRaisesRegex(ValueError,'archive hash'):suite.verify_sources()
if __name__=='__main__': unittest.main()
