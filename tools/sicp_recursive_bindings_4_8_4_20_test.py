#!/usr/bin/env python3
import json
from pathlib import Path
import shutil
import tempfile
import unittest

import sicp_coverage_report as coverage
import sicp_recursive_bindings_4_8_4_20 as named


class NamedLetEvidenceTests(unittest.TestCase):
    def test_example_is_extracted_from_original_exercise(self):
        source = named.original_example()
        self.assertIn('(let fib-iter', source)
        self.assertEqual(len(named.cases()), 8)
        self.assertIn('(fact 10)', named.factorial_example())
        self.assertTrue(all(case['setup'] == source for case in named.cases() if case['exercise'] == '4.8'))

    def test_coverage_records_partial_observations_and_rejects_invalid_rows(self):
        original = coverage.ROOT / 'docs/measurements/evidence/2026-11-02-xy-native-roots'
        evidence = coverage.ROOT / 'docs/measurements/evidence/2026-11-03-xy-recursive-bindings/current-sicp_recursive_bindings_4_8_4_20.json'
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory) / 'evidence'
            shutil.copytree(original, folder)
            target = folder / evidence.name
            shutil.copy2(evidence, target)
            result = coverage.report(folder)
            self.assertEqual(result['totals'], {'all_original_expression_steps': 1, 'sampled': 123, 'not_tested': 232})
            row = next(row for row in result['exercises'] if row['id'] == '4.8')
            self.assertEqual(row['coverage'], 'sampled')
            self.assertEqual(row['observations'], {'matched': 7})
            data = json.loads(target.read_text())
            data['cases'][0]['exercise'] = '4.9'
            target.write_text(json.dumps(data))
            with self.assertRaisesRegex(ValueError, 'batch exercise evidence'):
                coverage.report(folder)


if __name__ == '__main__':
    unittest.main()
