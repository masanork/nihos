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
SERIAL_CAPTURE = load('native_serial')


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
                           'tools/native-sqlite-manifest.py', 'tools/native-cold-policy.json', 'tools/native_serial.py'),
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


class PhysicalRemovalEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.image = {'io_lifetimes': {'version': 1, 'qualification': True, 'removal_test': True},
                      'memory': {'profile': 'device'}}
        self.record = dict.fromkeys(LOG.SD_REMOVAL_FIELDS, 0)
        self.record.update(version=1, status=1, before_reads=17, failed_command=17,
                           failed_interrupts=0x100, unpublished=1, fenced=1, idle_denied=1,
                           stale_rejected=2, reinserted=1, after_reads=2, crc=0x9022e83d,
                           generation_before=3, generation_after=4)

    def log(self, record=None):
        record = self.record if record is None else record
        return ('NIHOS_NATIVE_IO_LIFETIMES status=00000001\nNIHOS_SD_REMOVE_READY\nNIHOS_SD_INSERT_READY\n' +
                'NIHOS_NATIVE_SD_REMOVAL' + ''.join(f' {key}={record[key]:08x}' for key in LOG.SD_REMOVAL_FIELDS) + '\n')

    def check(self, log, image=None, evidence='physical-device'):
        return LOG.check_sd_removal(log, self.image if image is None else image,
                                    evidence, {'crc0': self.record['crc']})

    def test_hardware_record_passes_without_claiming_operator_confirmation(self):
        self.assertEqual(self.record, self.check(self.log()))
        self.assertNotIn('operator_confirmed', self.check(self.log()))

    def test_partial_stop_stale_generation_and_incorrect_data_fail(self):
        for key in LOG.SD_REMOVAL_FIELDS:
            if key in ('before_reads', 'failed_interrupts'):
                continue
            with self.subTest(field=key), self.assertRaises(ValueError):
                self.check(self.log({**self.record, key: self.record[key] ^ 1}))
        for count in (0, 20000):
            with self.assertRaises(ValueError):
                self.check(self.log({**self.record, 'before_reads': count}))

    def test_operator_phase_order_and_bound_image_are_required(self):
        log = self.log()
        for changed in (log.replace('NIHOS_SD_REMOVE_READY\n', ''),
                        log.replace('NIHOS_SD_INSERT_READY\n', 'NIHOS_SD_INSERT_READY\n' * 2),
                        log.replace('NIHOS_SD_REMOVE_READY\nNIHOS_SD_INSERT_READY\n',
                                    'NIHOS_SD_INSERT_READY\nNIHOS_SD_REMOVE_READY\n')):
            with self.assertRaises(ValueError):
                self.check(changed)
        with self.assertRaises(ValueError):
            self.check(log, {})
        with self.assertRaises(ValueError):
            self.check(log, evidence='emulator')

    def test_cold_boot_rejects_usb_watchdog_missing_and_mixed_reset_evidence(self):
        RUNNER.require_power_on_reset('rst:0x1 (POWERON_RESET),boot:0x20c\n')
        for log in ('', 'rst:0x17 (CHIP_USB_UART_RESET)', 'rst:0x7 (TG0WDT_SYS_RESET)',
                    'rst:0x1 (POWERON_RESET)\nrst:0x17 (CHIP_USB_UART_RESET)'):
            with self.assertRaises(ValueError):
                RUNNER.require_power_on_reset(log)


class PassiveCaptureTests(unittest.TestCase):
    def test_bound_latched_power_on_reason_survives_missing_rom_header(self):
        image = {'io_lifetimes': {'capture_handshake': True}, 'memory': {'profile': 'device'}}
        log = 'NIHOS_CAPTURE_WAIT\nNIHOS_NATIVE_RESET cpu0=00000001 ack=00000001\nNIHOS_NATIVE_BOOT backend=zig-sram\n'
        self.assertEqual(LOG.check_boot_capture(log, image, 'physical-device'), {'cpu0': 1, 'ack': 1})
        RUNNER.require_power_on_reset(log, image)
        for changed in (log.replace('cpu0=00000001', 'cpu0=00000017'),
                        log.replace('ack=00000001', 'ack=00000000'),
                        log + 'rst:0x17 (CHIP_USB_UART_RESET)\n', log + log):
            with self.assertRaises(ValueError):
                RUNNER.require_power_on_reset(changed, image)
        with self.assertRaises(ValueError):
            LOG.check_boot_capture(log, {}, 'physical-device')
        with self.assertRaises(ValueError):
            LOG.check_boot_capture(log, image, 'emulator')

    def test_passive_open_preserves_modem_lines_and_boot_bytes_but_normal_mode_restores_control(self):
        events = []

        class Base:
            def _reconfigure_port(self, **kwargs): events.append(('configure', kwargs))
            def _update_dtr_state(self): events.append('dtr')
            def _update_rts_state(self): events.append('rts')
            def _reset_input_buffer(self): events.append('flush')
            def open(self):
                self._reconfigure_port(force_update=True)
                self._update_dtr_state()
                self._update_rts_state()
                self._reset_input_buffer()

        Port = SERIAL_CAPTURE.capture_serial_class(Base, lambda _: events.append('disable_hupcl'))
        port = Port()
        port.passive_open = True
        port.open()
        self.assertEqual(events, [('configure', {'force_update': True}), 'disable_hupcl'])
        events.clear()
        port.passive_open = False
        port.open()
        self.assertEqual(events, [('configure', {'force_update': True}), 'dtr', 'rts', 'flush'])

    def test_reset_baseline_identity_hashes_and_three_runs_are_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            audit = {'image_sha256': 'image', 'elf_sha256': 'elf'}
            (directory / 'image-audit.json').write_text(json.dumps(audit))
            report = {'io_lifetimes': {'status': 1}}
            rows = []
            for run in range(1, 4):
                log = directory / f'boot{run}.log'
                log.write_text(f'boot {run}')
                rows.append({'run': run, 'log_sha256': RUNNER.digest(log), 'report': report})
            path = directory / 'results.json'
            path.write_text(json.dumps(rows))
            for name in ('verify-candidate-before.log', 'verify-candidate-after.log'):
                (directory / name).write_text('-- verify OK (digest matched)\n' * 3)

            class Check:
                @staticmethod
                def check(*args, **kwargs): return report

            self.assertEqual(RUNNER.validate_baseline(path, audit, Check)['runs'], 3)
            with self.assertRaises(ValueError):
                RUNNER.validate_baseline(path, {**audit, 'image_sha256': 'different'}, Check)
            path.write_text(json.dumps(rows[:2]))
            with self.assertRaises(ValueError):
                RUNNER.validate_baseline(path, audit, Check)
            path.write_text(json.dumps(rows))
            (directory / 'boot1.log').write_text('changed')
            with self.assertRaises(ValueError):
                RUNNER.validate_baseline(path, audit, Check)


if __name__ == '__main__':
    unittest.main()
