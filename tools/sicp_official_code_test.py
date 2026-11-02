#!/usr/bin/env python3
import tempfile
import unittest
from pathlib import Path
import sicp_official_code as source
import sicp_official_section1 as section


class OfficialCodeTests(unittest.TestCase):
    def test_complete_original_archive(self):
        files = source.inventory()
        self.assertEqual(set(files), source.NAMES)
        self.assertEqual(len(files), 21)
        self.assertEqual(files, source.inventory())
        self.assertTrue(all(v['bytes'] > 0 and len(v['sha256']) == 64 for v in files.values()))

    def test_first_section_examples_are_unmodified_and_complete(self):
        examples = section.source_examples()
        self.assertEqual(len(examples), 11)
        self.assertEqual(examples[0], '486')
        self.assertEqual(examples[4], '(/ 10 5)')
        self.assertEqual(examples[5], '(+ 2.7 10)')
        self.assertEqual(examples[-1], '(+ (* 3 (+ (* 2 4) (+ 3 5))) (+ (- 10 7) 6))')

    def test_altered_archive_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            altered = Path(directory) / 'allcode.tar.gz'
            altered.write_bytes(source.ARCHIVE.read_bytes() + b'altered')
            with self.assertRaisesRegex(ValueError, 'hash mismatch'):
                source.inventory(altered)


if __name__ == '__main__':
    unittest.main()
