#!/usr/bin/env python3
"""Stage the physically tested C6 source overlay in a disposable checkout.

Does not build, connect to a device, or flash. The checkout must be at the
pinned upstream revision with no tracked changes. Review changes before use.
"""
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
PORT = HERE.parent
REVISION = '0e8d0e3f0c2723deaf15441200cb4d8c53fea230'

def main():
    if len(sys.argv) != 2:
        raise SystemExit('usage: apply.py /path/to/disposable-esp-hosted-checkout')
    root = Path(sys.argv[1]).resolve()
    head = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
    if head != REVISION:
        raise SystemExit('unexpected ESP-Hosted revision')
    if subprocess.run(['git', '-C', str(root), 'diff', '--quiet', 'HEAD', '--']).returncode:
        raise SystemExit('checkout has tracked changes')
    targets = {}
    for name in ('nihos_time_service.c', 'nihos_time_service.h', 'nihos_time_wire.c', 'nihos_time_wire.h'):
        targets[root / 'slave/main' / name] = PORT / name
    for source in (HERE / 'unused-https').iterdir():
        targets[root / 'slave/main' / source.name] = source
    targets[root / 'slave/partitions.tab5-c6.csv'] = HERE / 'partitions.tab5-c6.csv'
    targets[root / 'slave/dependencies.lock'] = HERE / 'dependencies.lock'
    if any(path.exists() for path in targets):
        raise SystemExit('an overlay target already exists')
    subprocess.run(['git', '-C', str(root), 'apply', '--check', str(HERE / 'hosted-213-time.patch')], check=True)
    subprocess.run(['git', '-C', str(root), 'apply', str(HERE / 'hosted-213-time.patch')], check=True)
    for dest, source in targets.items():
        shutil.copyfile(source, dest)
    print('Staged time-candidate overlay; pass the recorded sdkconfig.time to ESP-IDF')

if __name__ == '__main__':
    main()
