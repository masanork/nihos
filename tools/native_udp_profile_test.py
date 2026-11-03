import os
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]


class NativeUdpProfile(unittest.TestCase):
    def test_invalid_udp_modes_fail_before_build(self):
        cases = [
            ({'NIHOS_NATIVE_EXPERIMENTAL_UDP': 'bad'}, 'EXPERIMENTAL_UDP must be 0 or 1'),
            ({'NIHOS_NATIVE_EXPERIMENTAL_UDP': '1', 'NIHOS_NATIVE_NETWORK': '0'}, 'EXPERIMENTAL_UDP requires'),
            ({'NIHOS_NATIVE_EXPERIMENTAL_UDP': '1', 'NIHOS_NATIVE_NETWORK': '1', 'NIHOS_C6_TIME_OFFLOAD': '0'}, 'EXPERIMENTAL_UDP requires'),
            ({'NIHOS_NATIVE_EXPERIMENTAL_UDP': '1', 'NIHOS_NATIVE_NETWORK': '1', 'NIHOS_C6_TIME_OFFLOAD': '1', 'NIHOS_NATIVE_EXPERIMENTAL_TCP': '1'}, 'EXPERIMENTAL_TCP does not support'),
        ]
        for settings, reason in cases:
            with self.subTest(settings=settings):
                env = {**os.environ, 'NIHOS_NATIVE_NETWORK': '0', 'NIHOS_NATIVE_EXPERIMENTAL_TCP': '0',
                       'NIHOS_C6_TIME_OFFLOAD': '0', **settings}
                result = subprocess.run(['sh', str(ROOT / 'tools/build-native-elf.sh'), 'device'],
                                        cwd=ROOT, env=env, capture_output=True, text=True, timeout=15)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(reason, result.stderr)


if __name__ == '__main__':
    unittest.main()
