"""Defect-exposing controls for the independent basic Japanese policy reference."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('kinsoku_reference', Path(__file__).resolve().parents[1] / 'probes/graphics/kinsoku_reference.py')
REF = importlib.util.module_from_spec(spec)
spec.loader.exec_module(REF)


def glyph(offset):
    return dict(run=0, cluster=offset, x_advance=32 * 64, y_advance=0,
                x_offset=0, y_offset=0, left=0, top=0)


class KinsokuReferenceTests(unittest.TestCase):
    def test_opening_bracket_moves_from_line_end_with_following_base(self):
        text = {'id': 5, 'glyphs': [glyph(i * 3) for i in range(4)]}
        positions, legal = REF.plan(text, ('日本「語', ''))
        _, naive = REF.plan(text, ('日本「語', ''), prohibit=False)
        self.assertEqual(positions[2], (8, 80))
        self.assertEqual(positions[3], (40, 80))
        self.assertEqual(legal['joined'], 1)
        self.assertEqual(legal['forbidden_ends'], 0)
        self.assertEqual(naive['forbidden_ends'], 1)

    def test_oversized_prohibited_chain_and_invalid_byte_offset_fail(self):
        text = {'id': 5, 'glyphs': [glyph(i * 3) for i in range(5)]}
        with self.assertRaisesRegex(ValueError, 'span exceeds'):
            REF.plan(text, ('「日。」語', ''))
        text = {'id': 5, 'glyphs': [glyph(1)]}
        with self.assertRaisesRegex(ValueError, 'scalar boundary'):
            REF.plan(text, ('日', ''))

    def test_paragraph_edges_and_basic_byte_boundaries(self):
        self.assertEqual(REF.boundaries('「日。」'), {0: True, 3: False, 6: False, 9: False, 12: True})
        self.assertFalse(REF.boundaries('きょ')[3])
        self.assertFalse(REF.boundaries('カー')[3])
        with self.assertRaises(ValueError):
            REF.boundaries('日\n本')
