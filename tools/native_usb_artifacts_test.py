"""Qualification consumes retained artifacts even if a build directory changes."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("capture_usb", Path(__file__).with_name("capture-native-usb.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RetainedUSBArtifacts(unittest.TestCase):
    def fixture(self, root):
        build, output = root / 'build', root / 'output'
        output.mkdir()
        for relative in ('loader/bootloader/bootloader.bin', 'loader/partition_table/partition-table.bin', 'nihos-native.bin'):
            path = build / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'original-' + relative.encode())
        audit = build / 'image-audit.json'
        audit.write_text(json.dumps({'rtos_linked': False, 'memory': {'profile': 'device'},
                                    'image_sha256': hashlib.sha256((build / 'nihos-native.bin').read_bytes()).hexdigest()}))
        return build, output, audit

    def test_original_audit_and_binaries_can_change_without_changing_capture_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            build, output, audit = self.fixture(Path(directory))
            original_audit = audit.read_bytes()
            paths, retained_audit = MODULE.snapshot_install(build, audit, output)
            audit.write_text('{}')
            (build / 'nihos-native.bin').write_bytes(b'different build')
            self.assertEqual(retained_audit.read_bytes(), original_audit)
            self.assertEqual(paths['0x10000'].read_bytes(), b'original-nihos-native.bin')

    def test_mismatched_app_is_rejected_before_any_serial_operation(self):
        with tempfile.TemporaryDirectory() as directory:
            build, output, audit = self.fixture(Path(directory))
            (build / 'nihos-native.bin').write_bytes(b'mismatch')
            with self.assertRaisesRegex(ValueError, 'retained installation image differs'):
                MODULE.snapshot_install(build, audit, output)

    def test_previous_evidence_directory_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            build, output, audit = self.fixture(Path(directory))
            paths, _ = MODULE.snapshot_install(build, audit, output)
            with self.assertRaises(FileExistsError):
                MODULE.snapshot_install(build, audit, output)
            self.assertEqual(paths['0x10000'].read_bytes(), b'original-nihos-native.bin')


if __name__ == '__main__':
    unittest.main()
