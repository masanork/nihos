"""The glyph benchmark must reject unsafe or unverified comparisons."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'tools/canvas_glyph_bench.py'


class GlyphBenchmarkInputTest(unittest.TestCase):
    def test_same_library_and_unverified_capture_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            baseline, candidate = root / 'baseline', root / 'candidate'
            baseline.write_bytes(b'not a library')
            candidate.write_bytes(b'not a library')
            (root / 'result.json').write_text('{}')
            same = subprocess.run([sys.executable, str(SCRIPT), str(baseline), str(baseline), '--host-dir', str(root)],
                                  capture_output=True, text=True, check=False)
            self.assertNotEqual(same.returncode, 0)
            self.assertIn('baseline and candidate libraries must be distinct files', same.stderr)
            unverified = subprocess.run([sys.executable, str(SCRIPT), str(baseline), str(candidate), '--host-dir', str(root)],
                                        capture_output=True, text=True, check=False)
            self.assertNotEqual(unverified.returncode, 0)
            self.assertIn('host shaping result differs from pinned reference', unverified.stderr)


if __name__ == '__main__':
    unittest.main()
