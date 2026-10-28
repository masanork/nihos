#!/usr/bin/env python3
"""Run the host tests under kcov on Linux and bind the result to source hashes."""
import argparse
from pathlib import Path
import platform
import os
import shutil
import signal
import subprocess
import tempfile

from metrics import ROOT, parse_cobertura, source_hashes, write_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kcov', required=True, type=Path)
    args = parser.parse_args()
    if platform.system() != 'Linux':
        parser.error('Run on Linux (or in a Linux container with ptrace enabled)')
    output = ROOT / 'build/metrics'
    output.mkdir(parents=True, exist_ok=True)
    report_path = output / 'host-coverage.json'
    report_path.unlink(missing_ok=True)
    before = source_hashes(ROOT)
    zig = ROOT / '.tools/zig-0.17.0/zig'
    # Fresh output prevents kcov from merging old hits into the current report.
    with tempfile.TemporaryDirectory(prefix='coverage-', dir=output) as stage:
        stage = Path(stage)
        binary = stage / 'host-tests'
        subprocess.run([str(zig), 'test', 'src/root.zig', '-O', 'Debug',
                        '--test-no-exec', f'-femit-bin={binary}'], cwd=ROOT, check=True)
        # Also execute directly so a collector cannot hide a failing test process.
        subprocess.run([str(binary)], cwd=ROOT, check=True)
        process = subprocess.Popen(
            [str(args.kcov.resolve()), f'--include-path={ROOT / "src"}',
             str(stage / 'kcov'), str(binary)], cwd=ROOT, start_new_session=True)
        try:
            result = process.wait(timeout=300)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise RuntimeError('kcov exceeded the 300-second collection limit') from None
        if result:
            raise RuntimeError(f'kcov exited with status {result}')
        xml = stage / 'kcov/host-tests/cobertura.xml'
        saved = output / 'kcov'
        if saved.exists():
            shutil.rmtree(saved)
        shutil.copytree(stage / 'kcov', saved)
        report = parse_cobertura(ROOT, xml, ROOT)
        if before != source_hashes(ROOT):
            raise ValueError('Source changed during coverage collection')
        report['host'] = {'system': platform.system(), 'machine': platform.machine()}
        report['zigVersion'] = subprocess.check_output([str(zig), 'version'], text=True).strip()
        write_json(report_path, report)
    c = report['lines']
    print(f"Host emitted implementation coverage: {c['percent']:.1f}% ({c['covered']}/{c['count']})")


if __name__ == '__main__':
    main()
