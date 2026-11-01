import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class FactoryC6BoundaryTests(unittest.TestCase):
    def test_staging_audit_requires_plain_burst(self):
        with tempfile.TemporaryDirectory() as directory:
            for burst, interval, reverse, valid in [('1', '250', '0', True), ('0', '250', '0', False), ('1', '500', '0', False), ('1', '250', '1', False)]:
                env = {**os.environ, 'NIHOS_C6_LONG_DMA': '1', 'NIHOS_C6_UDP_BURST': burst,
                       'NIHOS_C6_UDP_BURST_COUNT': '16', 'NIHOS_C6_UDP_INTERVAL_MS': interval,
                       'NIHOS_C6_UDP_REVERSE': reverse, 'NIHOS_C6_UDP_AUDIT_STAGING': '1',
                       'NIHOS_C6_UDP_TAIL_SHORT': '0', 'NIHOS_C6_UDP_PAUSE_AFTER_16': '0',
                       'NIHOS_C6_IPV6': '0', 'NIHOS_C6_UDP_PEER_IP': '192.0.2.2', 'NIHOS_C6_UDP_PEER_MAC': '02:00:00:00:00:02'}
                result = subprocess.run(['python3', str(ROOT / 'tools/c6-wifi-config.py'),
                                         str(Path(directory) / 'config.zig'), '', 'hosted'],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, valid)

    def test_extended_interval_requires_plain_sixteen_packet_burst(self):
        with tempfile.TemporaryDirectory() as directory:
            for burst, count, reverse, interval, valid in [('1', '16', '0', '500', True), ('0', '16', '0', '500', False), ('1', '18', '0', '500', False), ('1', '16', '1', '500', False), ('1', '16', '0', '400', False)]:
                env = {**os.environ, 'NIHOS_C6_LONG_DMA': '1', 'NIHOS_C6_UDP_BURST': burst,
                       'NIHOS_C6_UDP_BURST_COUNT': count, 'NIHOS_C6_UDP_INTERVAL_MS': interval,
                       'NIHOS_C6_UDP_REVERSE': reverse, 'NIHOS_C6_UDP_TAIL_SHORT': '0', 'NIHOS_C6_UDP_PAUSE_AFTER_16': '0',
                       'NIHOS_C6_IPV6': '0', 'NIHOS_C6_UDP_PEER_IP': '192.0.2.2', 'NIHOS_C6_UDP_PEER_MAC': '02:00:00:00:00:02'}
                result = subprocess.run(['python3', str(ROOT / 'tools/c6-wifi-config.py'),
                                         str(Path(directory) / 'config.zig'), '', 'hosted'],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, valid)

    def test_reverse_requires_plain_sixteen_packet_burst(self):
        with tempfile.TemporaryDirectory() as directory:
            for burst, count, tail, valid in [('1', '16', '0', True), ('0', '16', '0', False), ('1', '18', '0', False), ('1', '16', '1', False)]:
                env = {**os.environ, 'NIHOS_C6_LONG_DMA': '1', 'NIHOS_C6_UDP_BURST': burst,
                       'NIHOS_C6_UDP_BURST_COUNT': count, 'NIHOS_C6_UDP_REVERSE': '1',
                       'NIHOS_C6_UDP_TAIL_SHORT': tail, 'NIHOS_C6_UDP_PAUSE_AFTER_16': '0', 'NIHOS_C6_IPV6': '0',
                       'NIHOS_C6_UDP_PEER_IP': '192.0.2.2', 'NIHOS_C6_UDP_PEER_MAC': '02:00:00:00:00:02'}
                result = subprocess.run(['python3', str(ROOT / 'tools/c6-wifi-config.py'),
                                         str(Path(directory) / 'config.zig'), '', 'hosted'],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, valid)

    def test_pause_is_only_valid_for_seventeen_packet_burst(self):
        with tempfile.TemporaryDirectory() as directory:
            for burst, count, pause, valid in [('1', '17', '1', True), ('0', '17', '1', False), ('1', '16', '1', False), ('1', '17', '0', False)]:
                env = {**os.environ, 'NIHOS_C6_LONG_DMA': '1', 'NIHOS_C6_UDP_BURST': burst,
                       'NIHOS_C6_UDP_BURST_COUNT': count, 'NIHOS_C6_UDP_PAUSE_AFTER_16': pause,
                       'NIHOS_C6_UDP_TAIL_SHORT': '0', 'NIHOS_C6_IPV6': '0',
                       'NIHOS_C6_UDP_PEER_IP': '192.0.2.2', 'NIHOS_C6_UDP_PEER_MAC': '02:00:00:00:00:02'}
                result = subprocess.run(['python3', str(ROOT / 'tools/c6-wifi-config.py'),
                                         str(Path(directory) / 'config.zig'), '', 'hosted'],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, valid)

    def test_short_tail_requires_sixteen_packet_burst(self):
        with tempfile.TemporaryDirectory() as directory:
            for burst, count, valid in [('0', '16', False), ('1', '18', False), ('1', '16', True)]:
                env = {**os.environ, 'NIHOS_C6_LONG_DMA': '1', 'NIHOS_C6_UDP_BURST': burst,
                       'NIHOS_C6_UDP_BURST_COUNT': count, 'NIHOS_C6_UDP_TAIL_SHORT': '1', 'NIHOS_C6_IPV6': '0',
                       'NIHOS_C6_UDP_PEER_IP': '192.0.2.2', 'NIHOS_C6_UDP_PEER_MAC': '02:00:00:00:00:02'}
                result = subprocess.run(['python3', str(ROOT / 'tools/c6-wifi-config.py'),
                                         str(Path(directory) / 'config.zig'), '', 'hosted'],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, valid)

    def test_extra_sentinels_require_burst_and_exact_count(self):
        with tempfile.TemporaryDirectory() as directory:
            for burst, count, valid in [('0', '18', False), ('1', '17', False), ('1', '18', True)]:
                env = {**os.environ, 'NIHOS_C6_LONG_DMA': '1', 'NIHOS_C6_UDP_BURST': burst,
                       'NIHOS_C6_UDP_BURST_COUNT': count, 'NIHOS_C6_IPV6': '0',
                       'NIHOS_C6_UDP_PEER_IP': '192.0.2.2', 'NIHOS_C6_UDP_PEER_MAC': '02:00:00:00:00:02'}
                result = subprocess.run(['python3', str(ROOT / 'tools/c6-wifi-config.py'),
                                         str(Path(directory) / 'config.zig'), '', 'hosted'],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, valid)

    def test_extended_settle_requires_burst_and_known_duration(self):
        with tempfile.TemporaryDirectory() as directory:
            for burst, settle, valid in [('0', '8000', False), ('1', '5000', False), ('1', '8000', True)]:
                env = {**os.environ, 'NIHOS_C6_LONG_DMA': '1', 'NIHOS_C6_UDP_BURST': burst,
                       'NIHOS_C6_UDP_SETTLE_MS': settle, 'NIHOS_C6_IPV6': '0',
                       'NIHOS_C6_UDP_PEER_IP': '192.0.2.2', 'NIHOS_C6_UDP_PEER_MAC': '02:00:00:00:00:02'}
                result = subprocess.run(['python3', str(ROOT / 'tools/c6-wifi-config.py'),
                                         str(Path(directory) / 'config.zig'), '', 'hosted'],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, valid)

    def test_burst_requires_explicit_peer(self):
        with tempfile.TemporaryDirectory() as directory:
            env = {**os.environ, 'NIHOS_C6_LONG_DMA': '1', 'NIHOS_C6_UDP_BURST': '1',
                   'NIHOS_C6_IPV6': '0', 'NIHOS_C6_UDP_PEER_IP': '', 'NIHOS_C6_UDP_PEER_MAC': ''}
            result = subprocess.run(['python3', str(ROOT / 'tools/c6-wifi-config.py'),
                                     str(Path(directory) / 'config.zig'), '', 'hosted'],
                                    env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)

    def test_udp_probe_requires_explicit_unicast_peer_and_long_profile(self):
        cases = [('1', '192.0.2.2', '', False),
                 ('0', '192.0.2.2', '02:00:00:00:00:02', False),
                 ('1', '224.0.0.1', '02:00:00:00:00:02', False),
                 ('1', '192.0.2.2', 'ff:ff:ff:ff:ff:ff', False),
                 ('1', '192.0.2.2', '02:00:00:00:00:02', True)]
        with tempfile.TemporaryDirectory() as directory:
            for long_dma, ip, mac, valid in cases:
                env = {**os.environ, 'NIHOS_C6_LONG_DMA': long_dma, 'NIHOS_C6_IPV6': '0',
                       'NIHOS_C6_UDP_PEER_IP': ip, 'NIHOS_C6_UDP_PEER_MAC': mac,
                       'NIHOS_C6_UDP_PEER_PORT': '44444'}
                result = subprocess.run(['python3', str(ROOT / 'tools/c6-wifi-config.py'),
                                         str(Path(directory) / 'config.zig'), '', 'hosted'],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, valid)

    def test_long_dma_requires_hosted_profile(self):
        env = {**os.environ, 'NIHOS_C6_LONG_DMA': '1', 'NIHOS_C6_PROTOCOL': 'at'}
        result = subprocess.run(['sh', str(ROOT / 'tools/build-c6-sdio-probe.sh')],
                                env=env, capture_output=True, text=True, cwd=ROOT)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('NIHOS_C6_PROTOCOL=hosted', result.stderr)

    def test_long_dma_is_explicit_in_generated_config(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / 'config.zig'
            for flag in ('0', '1'):
                env = {**os.environ, 'NIHOS_C6_LONG_DMA': flag, 'NIHOS_C6_IPV6': '0'}
                result = subprocess.run(['python3', str(ROOT / 'tools/c6-wifi-config.py'),
                                         str(destination), '', 'hosted'], env=env,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('pub const long_dma = ' + ('true' if flag == '1' else 'false') + ';',
                              destination.read_text())

    def test_normal_sources_do_not_depend_on_custom_c6_experiment(self):
        forbidden = (
            'SplitHttpsClient', 'SplitStationClient', 'runHostedHttps',
            '@import("c6_https.zig")', '@import("network_split.zig")',
            'experimental/c6-custom-firmware',
        )
        for source in (ROOT / 'src').rglob('*.zig'):
            text = source.read_text()
            for reference in forbidden:
                with self.subTest(source=source.relative_to(ROOT), reference=reference):
                    self.assertNotIn(reference, text)



if __name__ == '__main__':
    unittest.main()
