#!/usr/bin/env python3
"""SICP source identity, semantic edges, exact UTF-8 anchors, and packed decoder."""
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

import xy_sicp as sicp
import xy_learning_pack as packed

ROOT = Path(__file__).resolve().parents[1]


class StructuredSicp(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compiled = sicp.compile_book()
        cls.library_bytes = (ROOT / 'assets/xy/library.json').read_bytes()
        cls.asset, cls.library = packed.load_asset(ROOT)
        cls.nodes = {n['id']: n for n in cls.asset['snippets']}

    def test_checked_in_assets_are_current_and_all_code_ranges_are_exact(self):
        sicp.validate_asset(self.asset, self.library_bytes)
        self.assertEqual(self.asset, sicp.learning_asset(self.compiled, self.library_bytes))
        self.assertEqual(len(self.nodes), 25)
        self.assertEqual(len(self.asset['experiments']), 21)
        anchored = {b['snippet'] for s in self.asset['sections'] for b in s['blocks'] if b['kind'] == 'code'}
        self.assertEqual(anchored, {s['id'] for s in self.nodes.values() if not s['hidden']})
        self.assertEqual(sum(s['hidden'] for s in self.nodes.values()), 4)

    def test_output_is_never_executable_and_reference_is_not_an_approved_grade(self):
        n = self.nodes['sicp.expressions.addition']
        self.assertEqual(n['code'], '(+ 137 349)')
        self.assertEqual(n['reference_output'], '486')
        self.assertIsNone(n['upstream_expected'])
        e = next(e for e in self.asset['experiments'] if e['editable'] == n['id'])
        self.assertEqual(e['run_order'], [n['id']])
        self.assertFalse(e['reference']['approved'])
        self.assertEqual(e['execution_status'], 'unqualified')

    def test_requires_and_example_remain_separate_and_variants_do_not_mix(self):
        exps = {e['id']: e for e in self.asset['experiments']}
        rec = exps['sicp.recursion.factorial-recursive.try']
        it = exps['sicp.recursion.factorial-iterative.try']
        self.assertEqual(rec['invocation'], it['invocation'])
        self.assertNotIn(it['editable'], rec['run_order'])
        self.assertNotIn(rec['editable'], it['run_order'])
        ack = exps['sicp.recursion.ackermann.try']
        self.assertEqual(ack['run_order'], ['sicp.recursion.ackermann', 'sicp.recursion.ackermann-1-10'])
        add = exps['sicp.recursion.addition-recursive.try']
        self.assertEqual(add['run_order'], ['sicp.recursion.inc-dec', 'sicp.recursion.addition-recursive', 'sicp.recursion.addition-call'])

    def test_unresolved_prerequisites_and_true_cycles_are_rejected(self):
        nodes = copy.deepcopy(self.nodes)
        key = 'sicp.expressions.addition'
        nodes[key]['requires'] = ['missing']
        with self.assertRaisesRegex(ValueError, 'Unresolved'):
            sicp.prerequisites([key], nodes)
        nodes[key]['requires'] = [key]
        with self.assertRaisesRegex(ValueError, 'REQUIRES cycle'):
            sicp.prerequisites([key], nodes)

    def test_utf8_offsets_are_emitted_with_code_and_not_rewritten_afterwards(self):
        root = ET.fromstring('<SECTION><TEXT>日本語 <SNIPPET><SCHEME>(+ 1\n  2)</SCHEME><SCHEMEOUTPUT>3</SCHEMEOUTPUT></SNIPPET> 本文</TEXT></SECTION>')
        node = root.find('.//SNIPPET')
        text, blocks = sicp.render(root, {node: {'id': 'test', 'code': '(+ 1\n  2)'}})
        block = next(b for b in blocks if b['kind'] == 'code')
        self.assertGreater(block['start'], text.index('(+'))
        self.assertEqual(text.encode()[block['start']:block['end']], b'(+ 1\n  2)')
        self.assertEqual([b['kind'] for b in blocks], ['code', 'reference_output'])

    def test_language_solutions_inline_prose_and_display_only_outputs_are_not_candidates(self):
        root = ET.fromstring('<SECTION><SCHEME>inline</SCHEME><SNIPPET><SCHEME_OUTPUT>4</SCHEME_OUTPUT></SNIPPET><JAVASCRIPT><SNIPPET><SCHEME>wrong</SCHEME></SNIPPET></JAVASCRIPT><SOLUTION><SNIPPET><SCHEME>secret</SCHEME></SNIPPET></SOLUTION><SNIPPET HIDE="yes"><SCHEME>support</SCHEME></SNIPPET></SECTION>')
        selected = sicp.candidates(root)
        self.assertEqual([sicp.xml_text(n.find('SCHEME')) for n in selected], ['support'])
        text, blocks = sicp.render(root, {})
        self.assertNotIn('secret', text)
        self.assertNotIn('wrong', text)
        self.assertNotIn('support', text)
        self.assertEqual([b['kind'] for b in blocks], ['reference_output'])

    def test_stale_library_wrong_anchor_and_invalid_plan_are_rejected(self):
        with self.assertRaisesRegex(ValueError, 'identity mismatch'):
            sicp.validate_asset(self.asset, self.library_bytes + b' ')
        broken = copy.deepcopy(self.asset)
        b = next(b for s in broken['sections'] for b in s['blocks'] if b['kind'] == 'code')
        b['end'] -= 1
        with self.assertRaisesRegex(ValueError, 'Code range mismatch'):
            sicp.validate_asset(broken, self.library_bytes)
        broken = copy.deepcopy(self.asset)
        broken['experiments'][0]['run_order'] *= 2
        with self.assertRaisesRegex(ValueError, 'run order'):
            sicp.validate_asset(broken, self.library_bytes)

    def test_manifest_ids_selectors_source_pins_and_unclassified_code_fail_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            vendor = Path(temp)
            for file in (ROOT / 'third_party/xy-reading').iterdir():
                if file.suffix in ('.xml', '.json'):
                    shutil.copy(file, vendor / file.name)
            manifest_path = vendor / 'sicp-experiments.json'
            original = json.loads(manifest_path.read_text())
            for defect in ('duplicate', 'missing', 'unclassified', 'source'):
                with self.subTest(defect=defect):
                    manifest = copy.deepcopy(original)
                    rows = manifest['sections'][1]['snippets']
                    if defect == 'duplicate':
                        rows[1]['id'] = rows[0]['id']
                    elif defect == 'missing':
                        rows[0]['selector'] = {'name': 'missing'}
                    elif defect == 'unclassified':
                        rows.pop()
                    else:
                        manifest['sections'][1]['sha256'] = '00' * 32
                    manifest_path.write_text(json.dumps(manifest))
                    with self.assertRaises(ValueError):
                        sicp.compile_book(vendor)

    def test_reordering_manifest_preserves_ids_source_order_and_run_plans(self):
        manifest = json.loads((ROOT / 'third_party/xy-reading/sicp-experiments.json').read_text())
        for section in manifest['sections']:
            section['snippets'].reverse()
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'manifest.json'
            path.write_text(json.dumps(manifest))
            compiled = sicp.compile_book(manifest_path=path)
        self.assertEqual(compiled['sections'], self.compiled['sections'])
        self.assertEqual(compiled['snippets'], self.compiled['snippets'])
        self.assertEqual(compiled['experiments'], self.compiled['experiments'])

    def test_ambiguous_source_and_display_only_prerequisite_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            vendor = Path(temp)
            for file in (ROOT / 'third_party/xy-reading').iterdir():
                if file.suffix in ('.xml', '.json'):
                    shutil.copy(file, vendor / file.name)
            path = vendor / 'sicp-experiments.json'
            manifest = json.loads(path.read_text())
            # An intentional upstream update must still resolve each selector uniquely.
            source = vendor / 'sicp-expressions.xml'
            root = ET.fromstring(source.read_bytes())
            root.append(ET.fromstring('<SNIPPET><SCHEME>486</SCHEME></SNIPPET>'))
            source.write_bytes(ET.tostring(root))
            digest = hashlib.sha256(source.read_bytes()).hexdigest()
            manifest['sections'][1]['sha256'] = digest
            pins = json.loads((vendor / 'sources.json').read_text())
            pins[source.name]['sha256'] = digest
            (vendor / 'sources.json').write_text(json.dumps(pins))
            path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, 'ambiguous'):
                sicp.compile_book(vendor)
        manifest = json.loads((ROOT / 'third_party/xy-reading/sicp-experiments.json').read_text())
        next(s for s in manifest['sections'][2]['snippets'] if s['id'] == 'sicp.recursion.inc-dec')['kind'] = 'display'
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'manifest.json'
            path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, 'display-only'):
                sicp.compile_book(manifest_path=path)

    def test_binary_catalogue_is_deterministic_and_binds_the_reading_library(self):
        data = packed.encode(self.asset, self.library)
        self.assertEqual(data, packed.encode(self.asset, self.library))
        self.assertEqual(data[:8], b'XYLAB001')
        self.assertEqual(data[64:96], hashlib.sha256(self.library_bytes).digest())
        oversized = copy.deepcopy(self.asset)
        oversized['snippets'][0]['code'] = 'x' * 4097
        with self.assertRaisesRegex(ValueError, 'format limit'):
            packed.encode(oversized, self.library)

    def test_real_zig_decoder_and_page_lookup(self):
        zig = os.environ.get('ZIG') or str(ROOT / '.tools/zig-0.17.0/zig')
        if not Path(zig).is_file():
            self.skipTest('Zig compiler unavailable; set ZIG to run the packed decoder contracts')
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            (folder / 'learning.pack').write_bytes(packed.encode(self.asset, self.library))
            legacy = copy.deepcopy(self.asset)
            for section in legacy['sections']: section['blocks'] = []
            old = bytearray(packed.encode(legacy, self.library)); struct.pack_into('<I',old,8,1)
            (folder / 'legacy.pack').write_bytes(old)
            (folder / 'fixture.zig').write_text('pub const data = @embedFile("learning.pack");\npub const legacy = @embedFile("legacy.pack");\n')
            result = subprocess.run([zig, 'test', '-O', 'ReleaseSafe', '--dep', 'learning_catalog', '--dep', 'learning_fixture',
                '-Mroot=' + str(ROOT / 'tools/probes/xy_learning_catalog.zig'),
                '-Mlearning_catalog=' + str(ROOT / 'src/xy/learning_catalog.zig'),
                '-Mlearning_fixture=' + str(folder / 'fixture.zig')], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
