"""Combined device evidence rejects implicit activity and unsafe reuse claims."""
import importlib.util
import contextlib
import hashlib
import io
import json
import sys
import tempfile
from unittest.mock import patch
from pathlib import Path
import unittest
import native_audio_test as AUDIO
import native_microphone_test as MICROPHONE
import native_rs485_test as RS485

SPEC = importlib.util.spec_from_file_location('combined_devices', Path(__file__).with_name('check-native-devices.py'))
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


def record(marker, fields, values):
    return marker + ' ' + ' '.join(key + '={:08x}'.format(values[key]) for key in fields) + '\n'


def log():
    service = dict(zip(CHECK.SERVICE_FIELDS, (7, 0, 0, 0, 0)))
    result = 'ESP-ROM:esp32p4\n' + record('NIHOS_NATIVE_DEVICE_SERVICE', CHECK.SERVICE_FIELDS, service) * 2
    for index, (kind, accepted, owner) in enumerate(CHECK.EXPECTED):
        values = dict(zip(CHECK.REQUEST_FIELDS, (kind, accepted, owner, 0, 0 if index == 0 else 1536)))
        result += record('NIHOS_DEVICE_REQUEST', CHECK.REQUEST_FIELDS, values)
        if accepted and kind in (1, 2, 3):
            proof = AUDIO.log(AUDIO.row()) if kind == 1 else MICROPHONE.capture() if kind == 2 else RS485.log()
            result += proof.split('\n', 1)[1]
            service['requested'] |= {1: 1, 2: 2, 3: 4}[kind]
            service['workspace'] = 1536
        result += record('NIHOS_NATIVE_DEVICE_SERVICE', CHECK.SERVICE_FIELDS, service)
        result += record('NIHOS_NATIVE_NETWORK_UI', ('frames', 'ticks0', 'ticks1'), dict(frames=index + 1, ticks0=index + 1, ticks1=index + 1))
    return result


class CombinedDeviceEvidenceTests(unittest.TestCase):
    def test_report_requires_restored_matching_image_elf_options_and_log(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            candidate = root / 'candidate'
            candidate.mkdir()
            image, elf, raw = b'image-fixture', b'elf-fixture', log().encode()
            options = ('pub const devices = true;\n' 'pub const network = true;\n'
                       'pub const console_live = true;\n' 'pub const audio = false;\n'
                       'pub const microphone = false;\n' 'pub const rs485 = false;\n').encode()
            digest = lambda data: hashlib.sha256(data).hexdigest()
            for name, data in (('nihos-native.bin', image), ('nihos-native.elf', elf), ('native_options.zig', options)):
                (candidate / name).write_bytes(data)
            (root / 'serial.log').write_bytes(raw)
            metadata = dict(written=True, restored=True, native_fail=False, serial_sha256=digest(raw), app_sha256=digest(image))
            (root / 'result.json').write_text(json.dumps(metadata))
            audit = dict(image_sha256=digest(image), elf_sha256=digest(elf), device_text=dict(foreground_only=True), heap=dict(bytes=50688))
            (candidate / 'retained-loader-audit.json').write_text(json.dumps(audit))
            receipt = dict(sdk_dirty=False, artifacts={name: digest(data) for name, data in
                           (('nihos-native.bin', image), ('nihos-native.elf', elf), ('native_options.zig', options))})
            (candidate / 'network-receipt.json').write_text(json.dumps(receipt))
            report = root / 'report.json'
            with patch.object(sys, 'argv', ['check', str(root), str(report)]), contextlib.redirect_stdout(io.StringIO()):
                CHECK.main()
                self.assertTrue(json.loads(report.read_text())['restored'])
                for name, original in (('nihos-native.bin', image), ('nihos-native.elf', elf), ('native_options.zig', options)):
                    (candidate / name).write_bytes(original + b'changed')
                    with self.assertRaises(ValueError):
                        CHECK.main()
                    (candidate / name).write_bytes(original)
                metadata['restored'] = False
                (root / 'result.json').write_text(json.dumps(metadata))
                with self.assertRaises(ValueError):
                    CHECK.main()

    def test_accepts_explicit_alternation_repeat_and_no_wire_claim(self):
        result = CHECK.check(log())
        self.assertEqual(len(result['operations']), 5)
        self.assertIn('external RS485 unqualified', result['scope'])
        self.assertEqual(result['service_final']['workspace'], 1536)

    def test_rejects_implicit_activity_mixed_boot_and_missing_requests(self):
        raw = log()
        for changed in ('ESP-ROM:esp32p4\n' + raw, raw + 'NIHOS_NATIVE_TRAP',
                        raw.replace('kind=00000005', 'kind=00000004', 1),
                        raw.replace('requested=00000000', 'requested=00000001', 1),
                        raw.replace('ESP-ROM:esp32p4\n', 'ESP-ROM:esp32p4\n' + AUDIO.row(), 1)):
            with self.assertRaises(ValueError):
                CHECK.check(changed)

    def test_rejects_accepted_overlap_pinned_or_growing_workspace(self):
        raw = log()
        for changed in (raw.replace('kind=00000001 accepted=00000000', 'kind=00000001 accepted=00000001'),
                        raw.replace('pinned=00000000', 'pinned=00000001', 1),
                        raw.replace('workspace=00000600', 'workspace=00000c00', 1)):
            with self.assertRaises(ValueError):
                CHECK.check(changed)

    def test_rejects_failed_cleanup_pcm_erasure_or_stopped_hart(self):
        raw = log()
        for changed in (raw.replace('returned=00000001', 'returned=00000000', 1),
                        raw.replace('erased=00000001', 'erased=00000000', 1),
                        raw.replace('ticks1=0000000c', 'ticks1=00000001')):
            with self.assertRaises(ValueError):
                CHECK.check(changed)


if __name__ == '__main__':
    unittest.main()
