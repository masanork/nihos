#!/usr/bin/env python3
"""Check headless normal-boot execution and intentional failures, never LCD timing."""
import argparse
import importlib.util
import json
from pathlib import Path

SPEC = importlib.util.spec_from_file_location('native_log', Path(__file__).with_name('check-native-log.py'))
NATIVE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NATIVE)
FAILURES = {3: 'CPU1 ready timeout', 4: 'boot health timeout', 5: 'boot health timeout'}


def check(log, image, psram_bytes, case):
    log = log.replace('\r', '')
    if (case not in (1, 2, 3, 4, 5) or image.get('rtos_linked') is not False or
            image.get('memory', {}).get('profile') != 'emulator'):
        raise ValueError('headless smoke requires an audited emulator image and known case')
    if (log.count('NIHOS_NATIVE_BOOT backend=zig-sram rtos=none') != 1 or
            log.count('NIHOS_NATIVE_PROFILE normal=1 qualification=0') != 1 or
            'NIHOS_NATIVE_TRAP' in log or 'NIHOS_NATIVE_UI_' in log):
        raise ValueError('reboot, trap, missing normal profile or invented display evidence')
    if NATIVE.fixed_record(log, 'NIHOS_NATIVE_BOOT_TEST', ('case',)) != {'case': case}:
        raise ValueError('wrong emulator test case')
    if case in FAILURES:
        expected = 'NIHOS_NATIVE_FAIL ' + FAILURES[case]
        failures = [line for line in log.splitlines() if line.startswith('NIHOS_NATIVE_FAIL')]
        if (failures != [expected] or
                any(marker in log for marker in ('NIHOS_NATIVE_NORMAL_READY', 'NIHOS_NATIVE_NORMAL_IDLE', 'NIHOS_NATIVE_BOOT_HEALTH'))):
            raise ValueError('missing expected timeout, wrong failure or premature READY')
        psram = NATIVE.fixed_record(log, 'NIHOS_NATIVE_PSRAM',
                                    ('status','configuration','identity','bytes','transactions','mapped','allocatable'))
        smp = NATIVE.fixed_record(log, 'NIHOS_NATIVE_PSRAM_SMP',
                                 ('status','rounds','owner_checks','peer_checks','command_checks','syncs'))
        if psram['mapped'] != psram_bytes or psram['bytes'] != psram_bytes or psram['status'] != int(psram_bytes != 0):
            raise ValueError('failure occurred before expected memory discovery')
        if list(smp.values()) != ([1,1,48,48,48,1] if psram_bytes else [0]*6):
            raise ValueError('failure occurred before cross-core memory rendezvous')
        return {'evidence': 'emulator', 'headless': True, 'case': case, 'expected_failure': expected,
                'ready': False, 'display_tested': False, 'psram200_tested': False}
    core = NATIVE.check(log, 'integer', psram_bytes, image, 'emulator', require_normal=True, headless_case=case)
    ready = NATIVE.fixed_record(log, 'NIHOS_NATIVE_NORMAL_READY', ('wait_us',))
    if not 0 < ready['wait_us'] <= 250_000 or (case == 2 and ready['wait_us'] < 50_000):
        raise ValueError('missing short health check or delayed CPU1 readiness wait')
    idle = NATIVE.repeated_records(log, 'NIHOS_NATIVE_NORMAL_IDLE',
                                  ('hart','ticks','work0','work1','switches','calls','reaped','sleeps'))
    if len(idle) != 2 or [r['hart'] for r in idle] != [0,1]:
        raise ValueError('missing per-core idle proof')
    for row in idle:
        before = core['health']['cpu{}_ticks'.format(row['hart'])]
        if row['ticks'] < before + 5 or any(row[key] for key in ('work0','work1','switches','calls','reaped','sleeps')):
            raise ValueError('idle timer stopped, or fixture tasks ran during normal boot')
    marker = 'NIHOS_NATIVE_NORMAL_IDLE_PASS headless=1 evidence=emulator'
    if (log.count(marker) != 1 or log.index(marker) < log.rindex('NIHOS_NATIVE_NORMAL_IDLE ')):
        raise ValueError('missing idle completion proof')
    return {'evidence': 'emulator', 'headless': True, 'case': case, 'core': core, 'ready': ready, 'idle': idle,
            'display_tested': False, 'psram200_tested': False, 'physical_boot_time_measured': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('audit', type=Path)
    parser.add_argument('report', type=Path)
    parser.add_argument('--psram', choices=NATIVE.PSRAM_SIZES, required=True)
    parser.add_argument('--case', type=int, required=True)
    args = parser.parse_args()
    result = check(args.log.read_text(), json.loads(args.audit.read_text()), NATIVE.PSRAM_SIZES[args.psram], args.case)
    args.report.write_text(json.dumps(result, indent=2) + '\n')
    print('Headless normal boot case {} passed (emulator only)'.format(args.case))


if __name__ == '__main__':
    main()
