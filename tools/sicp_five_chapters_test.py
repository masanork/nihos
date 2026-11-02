#!/usr/bin/env python3
"""Source provenance and independent test-data checks for the five-chapter run."""
import collections
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import sicp_abstraction_2_2_2_14 as abstraction
import sicp_fast_processes_1_16_1_28 as fast
import sicp_state_3_1_3_7 as state
import sicp_metacircular_4_1_4_7 as metacircular
import sicp_register_5_1_5_2 as register
import sicp_coverage_report as coverage

SUITES=(abstraction,fast,state,metacircular,register)

class FiveChaptersTests(unittest.TestCase):
    def test_pinned_sources_and_case_coverage(self):
        for suite in SUITES:
            with self.subTest(suite=suite.__name__):
                suite.verify_sources()
                rows=suite.cases()
                self.assertTrue(rows)
                self.assertTrue(all(r['expected'] and r['expression'] for r in rows))
        self.assertEqual(len(abstraction.cases()),45)
        self.assertEqual(len(fast.cases()),75)
        self.assertEqual(len(state.cases()),12)
        self.assertEqual(len(metacircular.cases()),15)
        self.assertEqual(len(register.cases()),10)
        self.assertTrue(fast.strong_witness_passes(2,13))
        self.assertFalse(fast.strong_witness_passes(2,561))

    def test_each_suite_rejects_changed_original_archive(self):
        with tempfile.TemporaryDirectory() as folder:
            bad=Path(folder)/'modified.tar.gz';bad.write_bytes(abstraction.official.ARCHIVE.read_bytes()+b'modified')
            for suite in SUITES:
                with self.subTest(suite=suite.__name__), mock.patch.object(suite.official,'ARCHIVE',bad):
                    with self.assertRaisesRegex(ValueError,'archive hash mismatch'):suite.verify_sources()

    def test_observed_coverage_reports_failures_not_only_successes(self):
        folder=coverage.ROOT/'docs/measurements/evidence/2026-11-02-sicp-five-chapters'
        report=coverage.report(folder)
        self.assertEqual(report['totals'],{'all_original_expression_steps':1,'sampled':50,'not_tested':305})
        self.assertEqual([sum(report['by_chapter'][str(i)].values()) for i in range(1,6)],list(coverage.MAXIMA))
        by_id={row['id']:row for row in report['exercises']}
        self.assertEqual(by_id['1.27']['observations'],{'matched':27,'error':9})
        self.assertEqual(by_id['3.1']['observations'],{'matched':2})
        self.assertEqual(by_id['5.2']['observations'],{'matched':5})
        data=json.loads((folder/'current-sicp_fast_processes_1_16_1_28.json').read_text())
        failures=[r for r in data['cases'] if r['status']=='error']
        self.assertEqual(len(failures),9)
        self.assertTrue(all(r['exercise']=='1.27' and r['variant']=='recursive' and r['observed']=='Depth' for r in failures))
        self.assertEqual(collections.Counter(r['variant'] for r in data['cases'] if r['exercise']=='1.27' and r['status']=='matched'),{'recursive':9,'iterative':18})

if __name__=='__main__':unittest.main()
