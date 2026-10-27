#!/usr/bin/env python3
"""Run audited normal-boot kernel cases without a physical display or device."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('boot_smoke', ROOT / 'tools/check-native-boot-smoke.py')
SMOKE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SMOKE)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/normal-boot-smoke')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    (output / 'report.json').unlink(missing_ok=True)
    emulator = subprocess.check_output(['sh', str(ROOT / 'tools/bootstrap-esp-emu.sh')], text=True).strip()
    version = subprocess.check_output([emulator, '--version'], text=True).strip()
    env = {key:value for key,value in os.environ.items() if not key.startswith('NIHOS_NATIVE_')}
    results = []
    for case in (1,2,3,4,5):
        case_dir = output / ('case-{}'.format(case))
        case_dir.mkdir(exist_ok=True)
        env.update(NIHOS_NATIVE_BOOT_TEST=str(case), NIHOS_NATIVE_QUALIFICATION='0')
        with (case_dir / 'build.log').open('w') as log:
            subprocess.run(['sh', str(ROOT / 'tools/build-native.sh'), 'emulator'], env=env,
                           cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
        build = ROOT / 'build/native-emulator'
        artifacts = {}
        for name in ('nihos-native.elf','nihos-native.bin','nihos-native-flash.bin','image-audit.json','native_options.zig'):
            shutil.copy2(build / name, case_dir / name)
            artifacts[name] = digest(case_dir / name)
        audit = json.loads((case_dir / 'image-audit.json').read_text())
        if digest(case_dir / 'nihos-native.bin') != audit['image_sha256']:
            raise ValueError('image/audit mismatch')
        sizes = ('0','4M','32M','64M') if case == 1 else ('32M',)
        for size in sizes:
            target = case_dir / size
            target.mkdir(exist_ok=True)
            report_path = target / 'result.json'
            report_path.unlink(missing_ok=True)
            # Wait for the complete UART line. Matching only its prefix can
            # stop the emulator before the failure reason/qualification flags
            # have drained, leaving a truncated record instead of evidence.
            marker = ('NIHOS_NATIVE_FAIL ' + SMOKE.FAILURES[case] if case in SMOKE.FAILURES
                      else 'NIHOS_NATIVE_NORMAL_IDLE_PASS headless=1 evidence=emulator') + '\r\n'
            with (target / 'emulator.log').open('w') as log:
                subprocess.run([emulator, '--chip','esp32p4','--firmware',str(case_dir / 'nihos-native-flash.bin'),
                                '--elf',str(case_dir / 'nihos-native.elf'),'--psram-size',size,'--timeout','15s',
                                '--exit-on',marker], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                               check=True, timeout=45)
            result = SMOKE.check((target / 'emulator.log').read_text(), audit, SMOKE.NATIVE.PSRAM_SIZES[size], case)
            report_path.write_text(json.dumps(result,indent=2)+'\n')
            results.append({'case':case, 'psram':size, 'artifacts':artifacts, 'result':result,
                            'log_sha256':digest(target / 'emulator.log'),
                            'log':str((target / 'emulator.log').relative_to(output))})
            print('case={} psram={} passed {}'.format(case,size,'expected timeout' if case in SMOKE.FAILURES else 'READY + idle'),flush=True)
    sources = subprocess.check_output(['git','ls-files','src','include','ports/esp32p4-native',
                                       'tools/build-native.sh','tools/build-native-elf.sh'],cwd=ROOT,text=True).splitlines()
    source_hash = hashlib.sha256()
    for name in sorted(sources):
        source_hash.update(name.encode()+b'\0'+(ROOT / name).read_bytes()+b'\0')
    report = {'evidence':'emulator', 'emulator_version':version, 'emulator_sha256':digest(Path(emulator)),
              'source_base_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
              'native_source_sha256':source_hash.hexdigest(), 'source_hash_paths':sorted(sources),
              'physical_device_used':False, 'display_tested':False,'psram200_tested':False,
              'physical_boot_time_measured':False,'cases':results}
    (output / 'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print('All {} headless emulator cases passed: {}'.format(len(results),output / 'report.json'),flush=True)


if __name__ == '__main__':
    main()
