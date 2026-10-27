"""Normal boot evidence cannot stand in for the full qualification harness.

Fixtures below are synthetic transformations of a retained qualification log;
they test the checker, never establish a physical normal-boot result.
"""
import importlib.util
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('native_log', ROOT / 'tools/check-native-log.py')
NATIVE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NATIVE)
DISPLAY_SPEC = importlib.util.spec_from_file_location('display_log', ROOT / 'tools/check-native-display-log.py')
DISPLAY = importlib.util.module_from_spec(DISPLAY_SPEC)
DISPLAY_SPEC.loader.exec_module(DISPLAY)
LOG = (ROOT / 'docs/measurements/2026-10-27-native-cpu360.log').read_text()
IMAGE = json.loads((ROOT / 'docs/measurements/2026-10-27-native-cpu360.json').read_text())['image_audit']


def synthetic_normal():
    removed = ('NIHOS_NATIVE_QUALIFICATION ', 'NIHOS_NATIVE_PSRAM_SWEEP ',
               'NIHOS_NATIVE_HEARTBEAT ', 'NIHOS_NATIVE_SOAK_PASS ', 'NIHOS_NATIVE_TASKS ')
    lines = [line for line in LOG.splitlines() if not line.startswith(removed)]
    smp = next(line for line in lines if line.startswith('NIHOS_NATIVE_PSRAM_SMP '))
    lines[lines.index(smp)] = smp.replace('rounds=00000040', 'rounds=00000001').replace('checks=00000c00', 'checks=00000030')
    position = next(i for i,line in enumerate(lines) if line.startswith('NIHOS_NATIVE_CONSOLE '))
    lines[position:position] = [
        'NIHOS_NATIVE_BOOT_HEALTH cpu0_ticks=00000001 cpu1_ticks=00000001 ipi0=00000001 ipi1=00000001',
        *['NIHOS_NATIVE_BOOT_TIME stage={:08x} elapsed_us={:08x}'.format(stage, i * 1000)
          for i,stage in enumerate((1,3,5,7,4,6), 1)],
    ]
    return 'NIHOS_NATIVE_PROFILE normal=1 qualification=0\n' + '\n'.join(lines) + '\n'


class NormalBootEvidenceTests(unittest.TestCase):
    def check(self, log=None):
        return NATIVE.check(synthetic_normal() if log is None else log, 'integer', 32 << 20,
                            IMAGE, 'physical-device', external_reserved_bytes=2 << 20, require_normal=True)

    def test_short_health_path_is_explicit_and_is_not_qualification(self):
        report = self.check()
        self.assertTrue(report['normal_boot'])
        self.assertIsNone(report['qualification'])
        self.assertEqual(report['psram_smp']['rounds'], 1)
        self.assertEqual(report['ready_us_from_diagnostic_clock'], 6000)
        with self.assertRaises(ValueError):
            NATIVE.check(synthetic_normal(), 'integer', 32 << 20, IMAGE, 'physical-device')
        with self.assertRaises(ValueError):
            self.check(LOG)

    def test_normal_display_retains_live_input_and_refresh_checks(self):
        report = DISPLAY.check(synthetic_normal(), IMAGE, 2, 80, require_console=True, normal_boot=True)
        self.assertTrue(report['native']['normal_boot'])
        self.assertEqual(report['live']['ready']['target'], 255)
        log = synthetic_normal()
        line = next(line for line in log.splitlines() if line.startswith('NIHOS_NATIVE_DISPLAY_IRQ_PASS '))
        with self.assertRaises(ValueError):
            DISPLAY.check(log.replace(line, ''), IMAGE, 2, 80, require_console=True, normal_boot=True)

    def test_missing_timer_or_ipi_and_duplicate_health_are_rejected(self):
        log = synthetic_normal()
        health = next(line for line in log.splitlines() if line.startswith('NIHOS_NATIVE_BOOT_HEALTH '))
        for field in ('cpu0_ticks', 'cpu1_ticks', 'ipi0', 'ipi1'):
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.check(log.replace(field+'=00000001', field+'=00000000'))
        for changed in (log.replace(health, ''), log + health + '\n'):
            with self.assertRaises(ValueError):
                self.check(changed)

    def test_missing_or_reordered_stage_and_workload_are_rejected(self):
        log = synthetic_normal()
        first = next(line for line in log.splitlines() if line.startswith('NIHOS_NATIVE_BOOT_TIME '))
        for changed in (log.replace(first, ''), log.replace('elapsed_us=000007d0', 'elapsed_us=00000001'),
                        log + 'NIHOS_NATIVE_SOAK_PASS rounds=300 timers=both rtos=none\n'):
            with self.assertRaises(ValueError):
                self.check(changed)

    def test_early_rejection_read_budget_keeps_100_samples_for_accepted_taps(self):
        log = synthetic_normal()
        tuning = NATIVE.fixed_record(log, 'NIHOS_NATIVE_PSRAM_TUNING',
                                    ('status','stage','phase_mask','phase','delay_mask','delay','repetitions','reads','writes','error_code'))
        valid = bin(tuning['delay_mask']).count('1')
        minimum = (6 + valid * 100 + 31 - valid) * 32
        original = tuning['reads']
        def with_reads(count):
            changed = log.replace('reads={:08x}'.format(original), 'reads={:08x}'.format(count))
            line = next(line for line in changed.splitlines() if line.startswith('NIHOS_NATIVE_PSRAM_IO '))
            transactions = int(re.search(r'transactions=([0-9a-f]{8})', line)[1], 16)
            return changed.replace(line, line.replace('transactions={:08x}'.format(transactions),
                                                       'transactions={:08x}'.format(transactions-original+count)))
        self.assertEqual(self.check(with_reads(minimum))['psram_fast']['tuning']['reads'], minimum)
        with self.assertRaises(ValueError):
            self.check(with_reads(minimum-32))
        with self.assertRaises(ValueError):
            self.check(log.replace('repetitions=00000064', 'repetitions=00000001'))


if __name__ == '__main__':
    unittest.main()
