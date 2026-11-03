import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class NativeUdpSmokeConfig(unittest.TestCase):
    def test_private_peer_validation_and_secret_redaction(self):
        cases = [({'ip': '192.0.2.2', 'mac': '02:00:00:00:00:02', 'port': 44444, 'bssid': '02:00:00:00:00:03'}, 0o600, True),
                 ({'ip': '192.0.2.2', 'mac': '02:00:00:00:00:02', 'port': 44444, 'bssid': 'ff:ff:ff:ff:ff:ff'}, 0o600, False),
                 ({'ip': '192.0.2.2', 'mac': '02:00:00:00:00:02', 'port': 44444}, 0o600, True),
                 ({'ip': '192.0.2.2', 'mac': '02:00:00:00:00:02', 'port': 44444}, 0o644, False),
                 ({'ip': '224.0.0.1', 'mac': '02:00:00:00:00:02', 'port': 44444}, 0o600, False),
                 ({'ip': '192.0.2.2', 'mac': 'ff:ff:ff:ff:ff:ff', 'port': 44444}, 0o600, False),
                 ({'ip': '192.0.2.2', 'mac': '02:00:00:00:00:02', 'port': 0}, 0o600, False)]
        with tempfile.TemporaryDirectory() as directory:
            peer = Path(directory) / 'private.json'
            destination = Path(directory) / 'config.zig'
            for data, mode, valid in cases:
                peer.write_text(json.dumps(data))
                peer.chmod(mode)
                destination.write_text('pub const enabled = true;\n')
                destination.chmod(0o600)
                result = subprocess.run(['python3', str(ROOT / 'tools/native-udp-smoke-config.py'),
                                         str(destination), str(peer)], capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, valid)
                self.assertNotIn(data['ip'], result.stdout + result.stderr)
                self.assertNotIn(data['mac'], result.stdout + result.stderr)
                if valid:
                    text = destination.read_text()
                    self.assertIn('pub const udp_smoke_port: u16 = 44444;', text)
                    self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
                else:
                    self.assertNotIn('udp_smoke_', destination.read_text())

    def test_probe_requires_experimental_udp_and_private_peer(self):
        env = {**os.environ, 'NIHOS_NATIVE_NETWORK': '1', 'NIHOS_C6_TIME_OFFLOAD': '1',
               'NIHOS_NATIVE_EXPERIMENTAL_TCP': '0', 'NIHOS_NATIVE_EXPERIMENTAL_UDP': '1',
               'NIHOS_NATIVE_UDP_SMOKE': '1', 'NIHOS_NATIVE_UDP_SMOKE_PEER': ''}
        result = subprocess.run(['sh', str(ROOT / 'tools/build-native-elf.sh'), 'device'],
                                cwd=ROOT, env=env, capture_output=True, text=True, timeout=15)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('UDP_SMOKE requires', result.stderr)


if __name__ == '__main__':
    unittest.main()
