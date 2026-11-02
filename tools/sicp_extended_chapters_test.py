#!/usr/bin/env python3
import collections
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import sicp_trees_2_19_2_32 as trees
import sicp_sequences_2_33_2_42 as sequences
import sicp_higher_order_1_29_1_46 as higher
import sicp_remaining_1_13_1_36 as remaining
import sicp_mutation_3_12_3_20 as mutation
import sicp_queues_3_21_3_23 as queues
import sicp_tables_3_24_3_27 as tables
import sicp_coverage_report as coverage

class ExtendedChaptersTests(unittest.TestCase):
    def test_provenance_and_independent_change_oracle(self):
        trees.verify_sources()
        self.assertEqual(trees.change(100,[50,25,10,5,1]),292)
        self.assertEqual(len(trees.cases()),34)
        self.assertEqual(len({r['exercise'] for r in trees.cases()}),13)
        sequences.verify_sources()
        self.assertEqual(sequences.queen_count(4),2)
        self.assertEqual(sequences.queen_count(8),92)
        self.assertEqual(len(sequences.cases()),29)
        higher.verify_sources()
        self.assertEqual(len(higher.cases()),39)
        remaining.verify_sources()
        self.assertEqual(len(remaining.cases()),23)
        self.assertEqual(remaining.tree_stats(11)[0],4)
        mutation.verify_sources()
        queues.verify_sources()
        tables.verify_sources()
        self.assertEqual(len(mutation.cases()),23)
        self.assertEqual(len(queues.cases()),10)
        self.assertEqual(len(tables.cases()),9)
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'bad.tar.gz';path.write_bytes(trees.official.ARCHIVE.read_bytes()+b'bad')
            with mock.patch.object(trees.official,'ARCHIVE',path):
                with self.assertRaisesRegex(ValueError,'archive hash mismatch'):trees.verify_sources()

    def test_coverage_preserves_failures_and_variadic_fix(self):
        folder=coverage.ROOT/'docs/measurements/evidence/2026-11-02-sicp-mutable-five'
        report=coverage.report(folder)
        self.assertEqual(report['totals'],{'all_original_expression_steps':1,'sampled':121,'not_tested':234})
        self.assertEqual([sum(report['by_chapter'][str(i)].values()) for i in range(1,6)],list(coverage.MAXIMA))
        rows={r['id']:r for r in report['exercises']}
        self.assertEqual(rows['2.20']['observations'],{'matched':3})
        self.assertEqual(rows['2.19']['observations'],{'matched':3,'error':2})
        self.assertEqual(rows['1.27']['observations'],{'matched':27,'error':9})
        self.assertEqual(rows['2.42']['observations'],{'matched':2,'error':2})
        self.assertEqual(rows['2.43']['observations'],{'matched':5,'error':1})
        self.assertEqual(rows['1.25']['observations'],{'matched':1,'error':1})
        self.assertEqual(rows['1.34']['observations'],{'matched':2})
        self.assertEqual(rows['1.36']['observations'],{'error':1})
        self.assertEqual(rows['3.13']['observations'],{'matched':2})
        self.assertEqual(rows['3.23']['observations'],{'matched':4})
        self.assertEqual(rows['3.27']['observations'],{'matched':2,'error':1})
        before=json.loads((folder/'before-variadic.json').read_text())
        after=json.loads((folder/'current-sicp_trees_2_19_2_32.json').read_text())
        self.assertEqual(collections.Counter(r['observed'] for r in before['cases'] if r['exercise']=='2.20'),{'Type':2})
        self.assertTrue(all(r['status']=='matched' for r in after['cases'] if r['exercise']=='2.20'))
        self.assertEqual(after['totals'],{'matched':32,'error':2})
        queens=json.loads((folder/'current-sicp_sequences_2_33_2_42.json').read_text())
        failed={r['expression']:r['observed'] for r in queens['cases'] if r['exercise']=='2.42' and r['status']=='error'}
        self.assertEqual(failed,{'(length (queens 4))':'HeapFull','(length (queens 8))':'Depth'})
        rest=json.loads((folder/'current-sicp_remaining_1_13_1_36.json').read_text())
        expected_errors=[r for r in rest['cases'] if r.get('expected_error')]
        self.assertEqual([(r['expression'],r['observed'],r['status']) for r in expected_errors],[('(f f)','Type','matched')])

if __name__=='__main__':unittest.main()
