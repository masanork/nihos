import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location('audio_check', Path(__file__).with_name('check-native-audio.py'))
AUDIO = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIO)


def row(**changes):
    values = dict(phase=7, fault=0, dma=0xb, bclk=262144, fifo=16384, eof_descriptor=0x4ff101f0,
                  parked=1, codec_off=1, stopped=1, returned=1)
    values.update(changes)
    return 'NIHOS_NATIVE_AUDIO ' + ' '.join(f'{name}={values[name]:08x}' for name in AUDIO.FIELDS) + '\n'


def log(record):
    return 'ESP-ROM:esp32p4\n' + record * 2 + 'NIHOS_NATIVE_AUDIO_IO ' + ' '.join(name + '=00000000' for name in AUDIO.IO_FIELDS) + '\n'


class AudioEvidenceTests(unittest.TestCase):
    def test_accepts_end_and_shutdown_without_claiming_audibility(self):
        result = AUDIO.check(log(row()))
        self.assertIn('audible output not evaluated', result['scope'])

    def test_rejects_missing_dma_progress_or_unreturned_buffers(self):
        for changes in ({'phase': 8}, {'fault': 1}, {'dma': 0}, {'dma': 0xc}, {'bclk': 0},
                        {'fifo': 0}, {'fifo': 8192}, {'bclk': 131072}, {'eof_descriptor': 0},
                        {'parked': 0}, {'parked': 2}, {'codec_off': 0}, {'stopped': 0}, {'returned': 0}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                AUDIO.check(log(row(**changes)))

    def test_rejects_malformed_records_mixed_boot_and_codec_failures(self):
        for candidate in (log(row()).replace('returned=', 'return='), log(row()) + 'ESP-ROM:esp32p4',
                          log(row() + row(phase=0)),
                          log(row()) + 'NIHOS_NATIVE_TRAP cause=', log(row()).replace('stage=00000000', 'stage=00000003')):
            with self.assertRaises(ValueError):
                AUDIO.check(candidate)


if __name__ == '__main__':
    unittest.main()
