"""Independent batch-reference coverage for multi-glyph indivisible clusters."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("flow_reference", Path(__file__).resolve().parents[1] / "probes/graphics/surface_reference.py")
REF = importlib.util.module_from_spec(spec)
spec.loader.exec_module(REF)


def glyph(cluster, pixels):
    return dict(run=0, cluster=cluster, x_advance=pixels * 64, y_advance=0,
                x_offset=0, y_offset=0, left=0, top=0)


class LineReferenceTests(unittest.TestCase):
    def test_multiple_glyphs_in_one_cluster_move_together(self):
        positions, stats = REF.wrapped_positions({"id": 5, "glyphs": [glyph(0, 64), glyph(3, 32), glyph(3, 32)]})
        self.assertEqual(positions, {0: (8, 48), 1: (8, 80), 2: (40, 80)})
        self.assertEqual(stats, dict(clusters=2, lines=2, wrapped_runs=1, transitions=1))

    def test_unbreakable_span_and_block_overflow_fail(self):
        for glyphs in ([glyph(0, 97)], [glyph(i, 96) for i in range(3)]):
            with self.subTest(glyphs=glyphs), self.assertRaises(ValueError):
                REF.wrapped_positions({"id": 5, "glyphs": glyphs})
