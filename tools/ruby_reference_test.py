"""Independent group-ruby reference controls, including source/cluster ranges."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('ruby_reference', Path(__file__).resolve().parents[1] / 'probes/graphics/ruby_reference.py')
REF = importlib.util.module_from_spec(spec)
spec.loader.exec_module(REF)


def glyph(run, offset):
    return dict(run=run, cluster=offset, x_advance=64, y_advance=0, x_offset=0, y_offset=0, left=0, top=0)


class RubyReferenceTests(unittest.TestCase):
    def test_wider_ruby_and_parent_move_as_one_centered_unit(self):
        text = {'id': 5, 'glyphs': [glyph(0, 0), glyph(0, 3), glyph(1, 0), glyph(1, 3), glyph(1, 6)]}
        annotations = [dict(base_start=0, base_end=6, ruby_start=0, ruby_end=9)]
        _, logical, stats = REF.plan(text, ('日本', 'にほん'), annotations, 192, 256, 2, 64, 80)
        self.assertEqual(logical[0], (32, 256))
        self.assertEqual(logical[2], (0, 176))
        self.assertEqual(stats['moved'], 1)
        self.assertEqual(stats['wide'], 1)

    def test_cluster_split_overlap_and_uncovered_ruby_fail(self):
        text = {'id': 5, 'glyphs': [glyph(0, 0), glyph(0, 0), glyph(1, 0)]}
        full = dict(base_start=0, base_end=6, ruby_start=0, ruby_end=3)
        for annotations in ([{**full, 'base_end': 3}], [full, full], []):
            with self.subTest(annotations=annotations), self.assertRaises(ValueError):
                REF.plan(text, ('日本', 'に'), annotations, 128, 256, 2, 0, 80)

    def test_two_annotations_bind_to_distinct_parent_positions(self):
        text = {'id': 5, 'glyphs': [glyph(0, 0), glyph(0, 3), glyph(1, 0), glyph(1, 3)]}
        annotations = [dict(base_start=0, base_end=3, ruby_start=0, ruby_end=3), dict(base_start=3, base_end=6, ruby_start=3, ruby_end=6)]
        _, logical, stats = REF.plan(text, ('日本', 'にほ'), annotations, 64, 160, 2, 0, 80)
        self.assertEqual(logical[3], (0, 80))
        self.assertEqual(stats['groups'], 2)
