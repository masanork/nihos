#!/usr/bin/env python3
import collections
import tempfile
import unittest
from pathlib import Path
import sicp_exercise_inventory as corpus


class CorpusInventory(unittest.TestCase):
    def test_complete_pinned_archive_and_stable_locations(self):
        rows = corpus.inventory()
        self.assertEqual(rows, corpus.inventory())
        self.assertEqual(len({(r['source'], r['ordinal_in_file']) for r in rows}), len(rows))
        counts = collections.Counter(r['source'].split('/')[1] for r in rows)
        self.assertEqual(counts, {'chapter1': 46, 'chapter2': 97, 'chapter3': 82, 'chapter4': 80, 'chapter5': 52})
        self.assertEqual(sum(r['status'] == 'unreviewed' for r in rows), 356)
        self.assertEqual([r['labels'] for r in rows if r['status'] == 'excluded_non_scheme'], [['ex:access_unassigned']])
        self.assertTrue(all(r['book_number'] is None for r in rows))

    def test_changed_source_fails_closed(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'changed.tar.gz'
            p.write_bytes(corpus.ARCHIVE.read_bytes() + b'changed')
            with self.assertRaisesRegex(ValueError, 'hash mismatch'):
                corpus.inventory(p)


if __name__ == '__main__':
    unittest.main()
