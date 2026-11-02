#!/usr/bin/env python3
"""Check source provenance and preserve expected gaps in mutable coverage."""
import collections
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import sicp_mutation_3_12_3_20 as mutation
import sicp_queues_3_21_3_23 as queues
import sicp_tables_3_24_3_27 as tables
import sicp_circuits_3_28_3_31 as circuits
import sicp_coverage_report as coverage

class MutableCoverageTests(unittest.TestCase):
    def test_pinned_sources_and_cases(self):
        for suite, count in ((mutation,23),(queues,10),(tables,9)):
            with self.subTest(suite=suite.__name__):
                suite.verify_sources(); self.assertEqual(len(suite.cases()),count)
        circuits.verify_sources(); self.assertEqual(len(circuits.cases()),18)
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'bad.tar.gz';p.write_bytes(mutation.official.ARCHIVE.read_bytes()+b'bad')
            for suite in (mutation,queues,tables,circuits):
                with self.subTest(suite=suite.__name__), mock.patch.object(suite.official,'ARCHIVE',p):
                    with self.assertRaisesRegex(ValueError,'archive hash mismatch'):suite.verify_sources()

    def test_observations_keep_resource_failures_and_expected_errors(self):
        folder=coverage.ROOT/'docs/measurements/evidence/2026-11-02-sicp-mutable-five'
        report=coverage.report(folder)
        self.assertEqual(report['totals'],{'all_original_expression_steps':1,'sampled':121,'not_tested':234})
        self.assertEqual([sum(report['by_chapter'][str(i)].values()) for i in range(1,6)],list(coverage.MAXIMA))
        rows={r['id']:r for r in report['exercises']}
        for exercise,expected in [('2.20',{'matched':3}),('2.19',{'matched':3,'error':2}),('1.27',{'matched':27,'error':9}),('2.42',{'matched':2,'error':2}),('2.43',{'matched':5,'error':1}),('1.25',{'matched':1,'error':1}),('1.36',{'error':1}),('3.13',{'matched':2}),('3.23',{'matched':4}),('3.27',{'matched':2,'error':1})]:
            with self.subTest(exercise=exercise):self.assertEqual(rows[exercise]['observations'],expected)
        self.assertEqual(rows['3.29']['observations'],{'error':5})
        self.assertEqual(rows['3.30']['observations'],{'error':4})
        self.assertEqual(rows['3.32']['observations'],{'matched':2})
        circuit_data=json.loads((folder/'current-sicp_circuits_3_28_3_31.json').read_text())
        self.assertTrue(all(r['stage']=='expression' for r in circuit_data['cases'] if r['status']=='error'))
        before=json.loads((folder/'before-variadic.json').read_text())
        self.assertEqual(collections.Counter(r['observed'] for r in before['cases'] if r['exercise']=='2.20'),{'Type':2})
        rest=json.loads((folder/'current-sicp_remaining_1_13_1_36.json').read_text())
        self.assertEqual([(r['expression'],r['observed'],r['status']) for r in rest['cases'] if r.get('expected_error')],[('(f f)','Type','matched')])
        for name in ('sicp_mutation_3_12_3_20','sicp_queues_3_21_3_23'):
            data=json.loads((folder/('current-'+name+'.json')).read_text())
            self.assertTrue(all(r['status']=='matched' for r in data['cases']))

if __name__=='__main__':unittest.main()
