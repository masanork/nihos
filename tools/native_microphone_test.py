import importlib.util
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('microphone', Path(__file__).with_name('check-native-microphone.py'))
MIC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MIC)


def record(marker, fields, values):
    return marker + ' ' + ' '.join(key + '={:08x}'.format(values.get(key, 0)) for key in fields) + '\n'


def capture(state=None, signal=None):
    values = dict(phase=5, fault=0, dma=3, end=0x4ff10000, parked=1, codec_off=1, stopped=1, returned=1, samples=512, erased=1)
    values.update(state or {})
    sig = dict(active=3, peak0=20, peak1=42, span0=30, span1=40)
    if signal is not None:
        sig = signal
    rows = record('NIHOS_NATIVE_MICROPHONE', MIC.FIELDS, values) + record('NIHOS_NATIVE_MICROPHONE_SIGNAL', MIC.SIGNAL_FIELDS, sig)
    return 'ESP-ROM:esp32p4\n' + rows * 2 + record('NIHOS_NATIVE_MICROPHONE_IO', MIC.IO_FIELDS, {})


class MicrophoneEvidenceTests(unittest.TestCase):
    def test_capture_and_muted_control_are_different_claims(self):
        self.assertFalse(MIC.check(capture())['muted_control'])
        self.assertTrue(MIC.check(capture(signal={}), muted=True)['muted_control'])
        with self.assertRaises(ValueError):
            MIC.check(capture(signal={}))
        with self.assertRaises(ValueError):
            MIC.check(capture(), muted=True)

    def test_rejects_dma_errors_live_buffers_short_capture_and_missing_erasure(self):
        for key in ('fault', 'phase', 'dma', 'end', 'parked', 'codec_off', 'stopped', 'returned', 'samples', 'erased'):
            value = 1 if key == 'fault' else 0
            with self.subTest(key=key), self.assertRaises(ValueError):
                MIC.check(capture({key: value}))
        for value in (0xb, 0x13, 0x23, 0x43):
            with self.assertRaises(ValueError):
                MIC.check(capture({'dma': value}))

    def test_rejects_mixed_boot_bad_statistics_and_unstable_completion(self):
        for raw in (capture() + 'ESP-ROM:esp32p4', capture() + 'NIHOS_NATIVE_TRAP',
                    capture(signal=dict(active=3, peak0=10, peak1=1, span0=100, span1=1)),
                    capture().replace('span0=0000001e', 'span0=0000ffff', 1)):
            with self.assertRaises(ValueError):
                MIC.check(raw)

    def test_incompatible_profiles_are_rejected_before_compilation(self):
        base = {k: v for k, v in os.environ.items() if not k.startswith('NIHOS_NATIVE_')}
        for extra, message in ((dict(NIHOS_NATIVE_MICROPHONE='1', NIHOS_NATIVE_AUDIO='1'), 'share I2S0'),
                               (dict(NIHOS_NATIVE_MICROPHONE='1'), 'normal native integer device'),
                               (dict(NIHOS_NATIVE_MICROPHONE_MUTED='1'), 'requires MICROPHONE=1')):
            env = dict(base, **extra)
            result = subprocess.run(['sh', str(ROOT / 'tools/build-native-elf.sh'), 'emulator'], env=env, cwd=ROOT,
                                    capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(message, result.stderr)


if __name__ == '__main__':
    unittest.main()
