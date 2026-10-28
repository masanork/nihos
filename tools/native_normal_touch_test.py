"""Negative controls for normal-touch evidence, not device simulation."""
import importlib.util
import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('touch', Path(__file__).with_name('check-native-touch.py'))
TOUCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TOUCH)


def record(marker, **values):
    return marker + ' ' + ' '.join(f'{key}={value:08x}' for key, value in values.items()) + '\n'


def fixture():
    log = 'ESP-ROM:esp32p4\n'
    for n in (0, 1):
        log += record('NIHOS_NATIVE_TOUCH_INPUT', status=1, panel=3, width=720, height=1280, slots=10,
                      polls=n * 50, fresh=n * 4, errors=0, error_code=0, max_poll_us=1000)
        log += record('NIHOS_NATIVE_POINTER', down=n * 2, move=0, up=n * 2, cancel=0, multi=0,
                      overflow=0, quadrants=n * 15, queued=0)
        log += record('NIHOS_NATIVE_NETWORK_UI', frames=n * 200, ticks0=n * 300, ticks1=n * 300)
        log += record('NIHOS_NATIVE_DEVICES', errors=0, samples=n * 5)
        log += record('NIHOS_NATIVE_IMU', initialized=1, fault=0, valid=1, samples=n * 100, sensor_error=0)
    log += record('NIHOS_NATIVE_TOUCH_UI', available=1, sources=17, x=1120, y=16, width=144, height=64)
    for n, view in ((1, 1), (2, 0)):
        log += record('NIHOS_NATIVE_DIAGNOSTIC_KEY', sequence=n, source=5, action=n, modifiers=0,
                      usage=1, accepted=1, view=view)
    return log


class TouchEvidenceTests(unittest.TestCase):
    def test_serial_success_preserves_optical_boundary(self):
        result = TOUCH.check(fixture())
        self.assertEqual(len(result['touch_actions']), 2)
        self.assertTrue(result['all_quadrants_observed'])
        self.assertIn('require operator evidence', result['scope'])

    def test_press_or_fabricated_view_record_cannot_replace_release(self):
        for before, after in (('up=00000002', 'up=00000000'), ('source=00000005', 'source=00000001'),
                              ('accepted=00000001', 'accepted=00000000'), ('view=00000000', 'view=00000001')):
            with self.subTest(before=before), self.assertRaises(ValueError):
                TOUCH.check(fixture().replace(before, after))

    def test_controller_queue_and_progress_failures_rejected(self):
        for before, after in (('error_code=00000000', 'error_code=00000004'),
                              ('overflow=00000000', 'overflow=00000001'),
                              ('sources=00000011', 'sources=00000001'),
                              ('ticks1=0000012c', 'ticks1=00000000'),
                              ('sensor_error=00000000', 'sensor_error=00000001')):
            with self.subTest(before=before), self.assertRaises(ValueError):
                TOUCH.check(fixture().replace(before, after))

    def test_mixed_or_malformed_capture_rejected(self):
        for extra in ('ESP-ROM:esp32p4\n', 'NIHOS_C6_BOOT\n', 'NIHOS_NATIVE_TRAP\n',
                      'NIHOS_NATIVE_TOUCH_INPUT status=garbage\n'):
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                TOUCH.check(fixture() + extra)

    def test_qualification_rejects_changed_candidate_archive_and_missing_restore(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate = root / 'candidate'
            candidate.mkdir()
            options = ''.join('pub const ' + key + ' = true;\n' for key in ('devices', 'network', 'console_live'))
            files = {'nihos-native.bin': b'synthetic-image', 'nihos-native.elf': b'synthetic-elf',
                     'native_options.zig': options.encode()}
            digest = lambda data: hashlib.sha256(data).hexdigest()
            for name, data in files.items():
                (candidate / name).write_bytes(data)
            (root / 'serial.log').write_text(fixture())
            content = b'synthetic source'
            with tarfile.open(candidate / 'qualification-source.tar.gz', 'w:gz') as archive:
                item = tarfile.TarInfo('source.zig')
                item.size = len(content)
                archive.addfile(item, io.BytesIO(content))
            metadata = dict(written=True, restored=True, commit='synthetic',
                            serial_sha256=digest((root / 'serial.log').read_bytes()),
                            app_sha256=digest(files['nihos-native.bin']), elf_sha256=digest(files['nihos-native.elf']),
                            source_archive_sha256=digest((candidate / 'qualification-source.tar.gz').read_bytes()))
            audit = dict(image_sha256=metadata['app_sha256'], elf_sha256=metadata['elf_sha256'], heap={'bytes': 49152})
            receipt = dict(sdk_dirty=False, sources={'source.zig': digest(content)},
                           artifacts={name: digest(data) for name, data in files.items()})
            for path, data in ((root / 'result.json', metadata), (candidate / 'retained-loader-audit.json', audit),
                               (candidate / 'network-receipt.json', receipt)):
                path.write_text(json.dumps(data))
            self.assertTrue(TOUCH.qualify(root)['restored'])
            metadata['restored'] = False
            (root / 'result.json').write_text(json.dumps(metadata))
            with self.assertRaisesRegex(ValueError, 'identity mismatch'):
                TOUCH.qualify(root)
            metadata['restored'] = True
            (root / 'result.json').write_text(json.dumps(metadata))
            (candidate / 'nihos-native.bin').write_bytes(b'foreign candidate')
            with self.assertRaisesRegex(ValueError, 'identity mismatch'):
                TOUCH.qualify(root)
            (candidate / 'nihos-native.bin').write_bytes(files['nihos-native.bin'])
            receipt['sources']['source.zig'] = digest(b'other source')
            (candidate / 'network-receipt.json').write_text(json.dumps(receipt))
            with self.assertRaisesRegex(ValueError, 'archive content mismatch'):
                TOUCH.qualify(root)


if __name__ == '__main__':
    unittest.main()
