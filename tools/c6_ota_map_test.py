"""Read-only candidate staging validation."""
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

PREPARE = Path(__file__).with_name('prepare-c6-ota-map.py')

class CandidateStagingTest(unittest.TestCase):
    def test_digest_and_c6_app_header_are_required(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate = root / 'source.bin'
            data = bytearray(64)
            data[0] = 0xe9
            data[12] = 13
            data[32:36] = bytes.fromhex('3254cdab')
            candidate.write_bytes(data)
            digest = hashlib.sha256(data).hexdigest()
            call = lambda checksum: subprocess.run([sys.executable, str(PREPARE), str(candidate), checksum, str(root)], capture_output=True)
            self.assertEqual(call('0' * 64).returncode, 1)
            self.assertFalse((root / 'candidate.bin').exists())
            self.assertEqual(call(digest).returncode, 0)
            self.assertEqual((root / 'candidate.bin').read_bytes(), data)
            data[32] = 0
            candidate.write_bytes(data)
            self.assertEqual(call(hashlib.sha256(data).hexdigest()).returncode, 1)

if __name__ == '__main__':
    unittest.main()
