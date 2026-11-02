#!/usr/bin/env python3
"""Check the provenance boundary and segmentation of the SICP sessions."""
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import sicp_official_sessions as sessions


class SessionSourceTests(unittest.TestCase):
    def test_expected_session_boundaries(self):
        extracted = sessions.source_sessions()
        self.assertEqual(list(extracted), ['section-1.1.2', 'exercise-1.1'])
        self.assertEqual((len(extracted['section-1.1.2']), len(extracted['exercise-1.1'])), (8, 13))
        self.assertEqual(extracted['exercise-1.1'][5:7], ['(define a 3)', '(define b (+ a 1))'])
        self.assertTrue(extracted['exercise-1.1'][-1].startswith('(* (cond '))

    def test_altered_archive_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            altered = Path(directory) / 'source.tar.gz'
            data = sessions.official.ARCHIVE.read_bytes()
            altered.write_bytes(data[:-1] + bytes([data[-1] ^ 1]))
            with mock.patch.object(sessions.official, 'ARCHIVE', altered):
                with self.assertRaisesRegex(ValueError, 'archive hash mismatch'):
                    sessions.source_sessions()


if __name__ == '__main__':
    unittest.main()
