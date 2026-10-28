import importlib.util
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tools' / path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


CHECK = module('rs485_checker', 'check-native-rs485.py')
PEER = module('rs485_peer', 'rs485-peer.py')


def log(**changes):
    values = dict(phase=7, fault=0, tx=64, rx=64, raw=0, tx_idle=1, dir_low=1, stopped=1, matched=1)
    values.update(changes)
    line = 'NIHOS_NATIVE_RS485 ' + ' '.join(key + '={:08x}'.format(values[key]) for key in CHECK.FIELDS) + '\n'
    return 'ESP-ROM:esp32p4\n' + line * 2 + 'NIHOS_NATIVE_RS485_IO stage=00000000 a=00000000 b=00000000 c=00000000\n'


class Rs485EvidenceTests(unittest.TestCase):
    def test_internal_and_peer_claims_are_distinct(self):
        self.assertIn('external RS485 transceiver/wire unqualified', CHECK.check(log())['scope'])
        self.assertIn('independent peer receipt still required', CHECK.check(log(), 'peer')['scope'])
        negative = log(phase=8, fault=4, rx=0, matched=0)
        self.assertEqual(CHECK.check(negative, 'no-loopback')['final']['fault'], 4)
        with self.assertRaises(ValueError):
            CHECK.check(negative)
        with self.assertRaises(ValueError):
            CHECK.check(log(), 'no-loopback')

    def test_rejects_incomplete_idle_direction_receive_and_cleanup(self):
        for key in ('tx', 'rx', 'tx_idle', 'dir_low', 'stopped', 'matched'):
            with self.subTest(key=key), self.assertRaises(ValueError):
                CHECK.check(log(**{key: 0}))
        for values in (dict(fault=2), dict(raw=0x10), dict(phase=8), dict(rx=65)):
            with self.assertRaises(ValueError):
                CHECK.check(log(**values))

    def test_rejects_partial_timeout_mixed_boot_and_transaction_restart(self):
        for raw, mode in ((log() + 'ESP-ROM:esp32p4', 'loopback'),
                          (log() + 'NIHOS_NATIVE_TRAP', 'loopback'),
                          (log().replace('stage=00000000', 'stage=00000002'), 'loopback'),
                          (log() + log().split('\n', 1)[1].replace('phase=00000007', 'phase=00000000'), 'loopback'),
                          (log(phase=8, fault=4, rx=1, matched=0), 'no-loopback')):
            with self.assertRaises(ValueError):
                CHECK.check(raw, mode)

    def test_peer_frame_crc_and_non_echo_response_match_native_fixture(self):
        self.assertEqual(PEER.crc16(b'123456789'), 0x29b1)
        self.assertEqual(len(PEER.frame()), 64)
        self.assertNotEqual(PEER.frame(), PEER.frame(True))
        for response in (False, True):
            data = PEER.frame(response)
            self.assertEqual(PEER.crc16(data[:-2]), int.from_bytes(data[-2:], 'big'))
            self.assertEqual(data[8], 2 if response else 1)

    def test_invalid_profiles_are_rejected_before_compilation(self):
        base = {k: v for k, v in os.environ.items() if not k.startswith('NIHOS_NATIVE_')}
        for extra, message in ((dict(NIHOS_NATIVE_RS485='1'), 'normal native integer device'),
                               (dict(NIHOS_NATIVE_RS485_TEST='peer'), 'requires RS485=1'),
                               (dict(NIHOS_NATIVE_RS485='1', NIHOS_NATIVE_MICROPHONE='1'), 'separate build')):
            result = subprocess.run(['sh', str(ROOT / 'tools/build-native-elf.sh'), 'emulator'], cwd=ROOT,
                                    env=dict(base, **extra), capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(message, result.stderr)


if __name__ == '__main__':
    unittest.main()
