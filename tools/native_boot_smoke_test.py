"""Regression checks against captured normal-path emulator runs and fault cases."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
DIRECTORY = ROOT / 'docs/measurements'
SPEC = importlib.util.spec_from_file_location('normal_boot_smoke', ROOT / 'tools/check-native-boot-smoke.py')
SMOKE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SMOKE)
RECEIPT = json.loads((DIRECTORY / '2026-10-27-native-normal-emulator.json').read_text())


def fixture(case):
    row = next(row for row in RECEIPT['cases'] if row['case'] == case and row['psram'] == '32M')
    return (DIRECTORY / row['retained_log']).read_text(), RECEIPT['image_audits'][str(case)]


class NormalBootSmokeTests(unittest.TestCase):
    def test_host_exit_marker_echo_cannot_duplicate_or_substitute_guest_evidence(self):
        log,audit=fixture(1)
        marker='NIHOS_NATIVE_NORMAL_IDLE_PASS headless=1 evidence=emulator'
        echo="[INFO  esp_emu] Exit-on string '"+marker+"\r\n' found in output\n"
        self.assertTrue(SMOKE.check(log+echo,audit,32<<20,1)['ready'])
        with self.assertRaises(ValueError):
            SMOKE.check(log.replace(marker,'INCOMPLETE')+echo,audit,32<<20,1)
        failed,image=fixture(3)
        reason='NIHOS_NATIVE_FAIL '+SMOKE.FAILURES[3]
        diagnostic="[INFO  esp_emu] Exit-on string '"+reason+"\r\n' found in output\n"
        with self.assertRaises(ValueError):
            SMOKE.check(failed.replace(reason,'INCOMPLETE')+diagnostic,image,32<<20,3)
    def test_real_normal_and_delayed_core_reach_ready_then_idle(self):
        for case in (1,2):
            with self.subTest(case=case):
                log,audit=fixture(case)
                result=SMOKE.check(log,audit,32<<20,case)
                self.assertEqual(result['evidence'],'emulator')
                self.assertFalse(result['display_tested'])
                self.assertFalse(result['physical_boot_time_measured'])
                self.assertTrue(result['core']['headless_emulator'])

    def test_recorded_memory_sizes_include_absent_and_both_boundaries(self):
        rows=[row for row in RECEIPT['cases'] if row['case']==1]
        self.assertEqual([row['psram'] for row in rows],['0','4M','32M','64M'])
        for row in rows:
            self.assertEqual(row['result']['core']['psram']['bytes'],SMOKE.NATIVE.PSRAM_SIZES[row['psram']])

    def test_real_missing_ready_ipi_and_timer_fail_without_ready(self):
        for case in (3,4,5):
            with self.subTest(case=case):
                log,audit=fixture(case)
                result=SMOKE.check(log,audit,32<<20,case)
                self.assertFalse(result['ready'])
                self.assertIn('timeout',result['expected_failure'])
                # The emulator also echoes the exit marker in its INFO line.
                self.assertGreater(log.count('NIHOS_NATIVE_FAIL'),1)
                with self.assertRaises(ValueError):
                    SMOKE.check(log+'\nNIHOS_NATIVE_NORMAL_READY wait_us=00000001\n',audit,32<<20,case)

    def test_stopped_idle_timer_or_accidental_fixture_worker_is_rejected(self):
        log,audit=fixture(1)
        idle=next(line for line in log.splitlines() if line.startswith('NIHOS_NATIVE_NORMAL_IDLE '))
        for field in ('ticks','work0','work1','switches','calls','reaped','sleeps'):
            value='00000000' if field=='ticks' else '00000001'
            tokens=idle.split()
            changed=' '.join(field+'='+value if token.startswith(field+'=') else token for token in tokens)
            with self.subTest(field=field),self.assertRaises(ValueError):
                SMOKE.check(log.replace(idle,changed),audit,32<<20,1)

    def test_headless_results_cannot_be_accepted_as_physical_or_qualification(self):
        log,audit=fixture(1)
        with self.assertRaises(ValueError):
            SMOKE.NATIVE.check(log,'integer',32<<20,audit,'emulator')
        with self.assertRaises(ValueError):
            SMOKE.NATIVE.check(log,'integer',32<<20,audit,'physical-device',require_normal=True,headless_case=1)
        wrong=dict(audit,memory=dict(audit['memory'],profile='device'))
        with self.assertRaises(ValueError):
            SMOKE.check(log,wrong,32<<20,1)

    def test_fault_injection_is_rejected_for_device_build_before_compilation(self):
        env={key:value for key,value in os.environ.items() if not key.startswith('NIHOS_NATIVE_')}
        env['NIHOS_NATIVE_BOOT_TEST']='5'
        result=subprocess.run(['sh',str(ROOT/'tools/build-native-elf.sh'),'device'],cwd=ROOT,env=env,capture_output=True,text=True,timeout=10)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('Boot test requires headless emulator',result.stderr)


if __name__=='__main__':
    unittest.main()
