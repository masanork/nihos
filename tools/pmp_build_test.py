"""Reject a probe selector on a non-probe image before building."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class PmpBuildTests(unittest.TestCase):
    def refused(self, probe, case, message):
        root = Path(__file__).resolve().parents[1]
        env = {key: value for key, value in os.environ.items()
               if not key.startswith('NIHOS_NATIVE_')}
        env.update(NIHOS_NATIVE_PMP_PROBE=probe, NIHOS_NATIVE_PMP_CASE=case)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'must not be created'
            result = subprocess.run(['sh', str(root / 'tools/build-native-elf.sh'),
                                     'device', str(output)], env=env, cwd=root,
                                    capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(message, result.stderr)
            self.assertFalse(output.exists())

    def test_a_selector_cannot_silently_run_a_non_probe_image(self):
        self.refused('0', '11', 'requires NIHOS_NATIVE_PMP_PROBE=1')


if __name__ == '__main__':
    unittest.main()
