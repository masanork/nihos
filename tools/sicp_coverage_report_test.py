#!/usr/bin/env python3
import json
from pathlib import Path
import shutil
import tempfile
import unittest
import sicp_coverage_report as coverage

class CoverageReportTests(unittest.TestCase):
    def test_book_denominator_and_observations(self):
        report = coverage.report(coverage.DEFAULT)
        self.assertEqual(report['totals'], {'all_original_expression_steps': 1, 'sampled': 11, 'not_tested': 344})
        self.assertEqual([sum(report['by_chapter'][str(i)].values()) for i in range(1, 6)], list(coverage.MAXIMA))
        self.assertEqual(report['exercises'][0]['id'], '1.1')
        self.assertEqual(report['exercises'][-1]['id'], '5.52')
        self.assertTrue(all(row['evidence'] is None for row in report['exercises'] if row['coverage'] == 'not_tested'))

    def test_incomplete_index_and_missing_exercise_evidence_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp) / 'evidence'
            shutil.copytree(coverage.DEFAULT, folder)
            index_path = folder / 'mit-exercise-index.json'
            original = index_path.read_text(); index = json.loads(original)
            index['exercises'][1]['id'] = index['exercises'][0]['id']
            index_path.write_text(json.dumps(index))
            with self.assertRaisesRegex(ValueError, 'index'): coverage.report(folder)
            index_path.write_text(original)
            proof_path = folder / coverage.EVIDENCE['1.1']; proof = json.loads(proof_path.read_text())
            proof['sessions'][1]['forms'].pop()
            proof_path.write_text(json.dumps(proof))
            with self.assertRaisesRegex(ValueError, '1.1 evidence'): coverage.report(folder)

    def test_chapter_two_proof_extends_only_its_exercises(self):
        folder = coverage.ROOT / 'docs/measurements/evidence/2026-11-02-sicp-lists-2'
        report = coverage.report(folder)
        self.assertEqual(report['totals'], {'all_original_expression_steps': 1, 'sampled': 14, 'not_tested': 341})
        self.assertEqual(report['by_chapter']['2'], {'sampled': 3, 'not_tested': 94})

    def test_rational_evidence_adds_one_sample_and_rejects_empty_cases(self):
        source = coverage.ROOT / 'docs/measurements/evidence/2026-11-02-sicp-letstar'
        report = coverage.report(source)
        self.assertEqual(report['totals'], {'all_original_expression_steps': 1, 'sampled': 15, 'not_tested': 340})
        self.assertEqual(report['by_chapter']['2'], {'sampled': 4, 'not_tested': 93})
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp) / 'evidence'
            shutil.copytree(source, folder)
            path = folder / 'current-sicp_rational_2_1.json'
            proof = json.loads(path.read_text()); proof['cases'] = []
            path.write_text(json.dumps(proof))
            with self.assertRaisesRegex(ValueError, 'rational exercise'): coverage.report(folder)

    def test_symbol_evidence_adds_only_its_three_exercises(self):
        folder = coverage.ROOT / 'docs/measurements/evidence/2026-11-02-sicp-equality'
        report = coverage.report(folder)
        self.assertEqual(report['totals'], {'all_original_expression_steps': 1, 'sampled': 18, 'not_tested': 337})
        self.assertEqual(report['by_chapter']['2'], {'sampled': 7, 'not_tested': 90})

if __name__ == '__main__': unittest.main()
