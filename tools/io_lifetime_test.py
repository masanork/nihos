"""Reject incomplete or falsely attributed native SD lifetime evidence."""
import copy
import importlib.util
import hashlib
import json
from pathlib import Path
import unittest
import tempfile


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


LOG = load('check-native-log')
IMAGE = load('check-native-image')
RUNNER = load('qualify-storage-io')


class LifetimeEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.image = {'io_lifetimes': {'version': 1, 'qualification': True}, 'memory': {'profile': 'device'}}
        self.record = dict.fromkeys(LOG.IO_LIFETIME_FIELDS, 0)
        self.record.update(version=1, status=1, normal_reads=2, cancelled=1, removed=1, stale_rejected=3,
                           idle_denied=1, fences=2, unpublished=2, crc=0x9022e83d)

    def log(self, record=None):
        record = record if record is not None else self.record
        return 'NIHOS_NATIVE_IO_LIFETIMES' + ''.join(f' {key}={record[key]:08x}' for key in LOG.IO_LIFETIME_FIELDS) + '\n'

    def check(self, log, image=None, evidence='physical-device'):
        return LOG.check_io_lifetimes(log, image if image is not None else self.image,
                                      evidence, {'crc0': self.record['crc']})

    def test_exact_record_passes_and_old_images_remain_distinct(self):
        self.assertEqual(self.check(self.log()), self.record)
        self.assertIsNone(self.check('', {}))

    def test_every_missing_or_incorrect_result_is_rejected(self):
        for key in LOG.IO_LIFETIME_FIELDS:
            changed = {**self.record, key: self.record[key] ^ 1}
            with self.subTest(field=key), self.assertRaises(ValueError):
                self.check(self.log(changed))

    def test_duplicate_missing_malformed_or_unbound_records_fail(self):
        for text in ('', self.log() * 2, self.log().replace('status=', 'invalid=')):
            with self.assertRaises(ValueError):
                self.check(text)
        with self.assertRaises(ValueError):
            self.check(self.log(), {})
        with self.assertRaises(ValueError):
            self.check(self.log(), evidence='emulator')
        image = copy.deepcopy(self.image)
        image['memory']['profile'] = 'emulator'
        with self.assertRaises(ValueError):
            self.check(self.log(), image)

    def test_irq_hooks_and_lease_metadata_must_remain_resident(self):
        low, high = 0x4ff00000, 0x4ff28000
        symbols = dict.fromkeys(('nih_storage_io_active', 'nih_storage_io_stop', 'nih_storage_io_removed',
                                 'sdmmc_probe.io_owner', 'sdmmc_probe.io_signal'), low + 256)
        sizes = {'sdmmc_probe.io_owner': 80, 'sdmmc_probe.io_signal': 12}
        paths = ('src/fs/io_leases.zig', 'src/fs/io_stop.zig', 'src/fs/sdmmc_owner.zig',
                 'src/soc/esp32p4/sdmmc.zig', 'src/platform/native/sdmmc_probe.zig',
                'src/platform/native/main.zig', 'src/diagnostics/record.zig', 'include/nihos_storage_io.h')
        config = {**self.image['io_lifetimes'], 'sources': dict.fromkeys(paths, '1' * 64)}
        IMAGE.audit_io_lifetimes(config, symbols, sizes, low, high)
        for name in symbols:
            for address in (0x40001120, 0x48004000, high):
                with self.subTest(symbol=name, address=address), self.assertRaises(ValueError):
                    IMAGE.audit_io_lifetimes(config, {**symbols, name: address}, sizes, low, high)
        with self.assertRaises(ValueError):
            IMAGE.audit_io_lifetimes({**config, 'sources': {}}, symbols, sizes, low, high)

    def test_runner_rejects_changed_or_incomplete_frozen_artifacts_before_serial_access(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            candidate, loader, source = (root / key for key in ('candidate', 'loader', 'source'))
            names = {
                'candidate': ('nihos-native.bin', 'nihos-native.elf', 'image-audit.json', 'sqlite-manifest.json', 'native_options.zig', 'native-layout.ld'),
                'loader': ('bootloader.bin', 'bootloader.elf', 'partition-table.bin', 'loader-sdkconfig.h'),
                'source': ('tools/qualify-storage-io.py', 'tools/check-native-log.py', 'tools/check-native-image.py',
                           'tools/native-sqlite-manifest.py', 'tools/native-cold-policy.json'),
            }
            bundle = {}
            for key, files in names.items():
                bundle[key] = {}
                for name in files:
                    path = root / key / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(b'fixture')
                    bundle[key][name] = hashlib.sha256(b'fixture').hexdigest()
            manifest = candidate / 'qualification-bundle.json'
            manifest.write_text(json.dumps(bundle))
            RUNNER.validate_bundle(candidate, loader, source)
            (loader / 'bootloader.bin').write_bytes(b'changed')
            with self.assertRaises(ValueError):
                RUNNER.validate_bundle(candidate, loader, source)
            bundle['loader'] = {}
            manifest.write_text(json.dumps(bundle))
            with self.assertRaises(ValueError):
                RUNNER.validate_bundle(candidate, loader, source)


if __name__ == '__main__':
    unittest.main()
