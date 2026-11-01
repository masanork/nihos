"""Reproducibility and checksum of the synthetic DHCP renewal ACK."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FIX = ROOT / 'src/net/fixtures'


class RenewalFixtureTest(unittest.TestCase):
    def test_regeneration_and_udp_checksum(self):
        with tempfile.TemporaryDirectory() as temp:
            result = Path(temp) / 'renew.bin'
            subprocess.run([sys.executable, str(FIX / 'generate-dhcp-renew.py'), str(result)], check=True)
            actual = result.read_bytes()
        original = (FIX / 'dhcp-ack.bin').read_bytes()
        self.assertEqual(actual, (FIX / 'dhcp-renew-ack.bin').read_bytes())
        self.assertEqual(len(actual), len(original))
        changed = {i for i, (a, b) in enumerate(zip(actual, original)) if a != b}
        self.assertTrue(changed <= set(range(46, 50)) | {40, 41})
        self.assertEqual(int.from_bytes(actual[46:50], 'big'), 0xb06bd031)
        udp_len = int.from_bytes(actual[38:40], 'big')
        pseudo = actual[26:34] + b'\x00\x11' + udp_len.to_bytes(2, 'big')
        data = pseudo + actual[34:34 + udp_len]
        if len(data) & 1:
            data += b'\x00'
        total = sum(int.from_bytes(data[i:i + 2], 'big') for i in range(0, len(data), 2))
        while total >> 16:
            total = (total & 0xffff) + (total >> 16)
        self.assertNotEqual(actual[40:42], b'\x00\x00')
        self.assertEqual(total, 0xffff)


if __name__ == '__main__':
    unittest.main()
