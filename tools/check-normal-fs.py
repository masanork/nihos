#!/usr/bin/env python3
"""Actual normal FS task + FatFs/VFS/RPC/SD driver, hosted MMIO only.

Uses isolated sparse writable fixture generation; the tested service opens
images read-only. UI/SDIO turns are a deterministic scheduler model, not device
latency, IRQ-removal or whole-stack qualification.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import tempfile
from normal_fs_build import build

ROOT = Path(__file__).resolve().parents[1]
FORMATS = ('fat12', 'fat16', 'fat32', 'mbr-fat32', 'exfat')
MODES = ('success', 'no-card', 'generation', 'io-error', 'quarantine', 'removed', 'corrupt', 'no-memory', 'empty-root')


def sha(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def execute(command, success=True):
    result = subprocess.run(list(map(str, command)), capture_output=True, text=True, timeout=120,
        env={**os.environ, 'ASAN_OPTIONS': 'abort_on_error=1:detect_leaks=0', 'UBSAN_OPTIONS': 'halt_on_error=1:print_stacktrace=1'})
    if success and (result.returncode or result.stderr):
        raise RuntimeError(str(command) + '\n' + result.stdout + '\n' + result.stderr)
    return result


def link(work, objects):
    out = work / 'check'
    execute([*shlex.split(os.environ.get('CC', 'cc')), '-std=c11', '-Wall', '-Wextra', '-Werror', '-O1', '-g',
        '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I' + str(ROOT / 'src/platform/native'),
        ROOT / 'probes/normal-fs/check.c', *objects[1:], objects[0], '-o', out])
    return out


def root_sector(image, fixture):
    if fixture['root_cluster']:
        return fixture['data_byte'] // 512 + (fixture['root_cluster'] - 2) * (fixture['cluster_bytes'] // 512)
    with image.open('rb') as stream:
        stream.seek(fixture['volume_byte'])
        boot = stream.read(512)
    return fixture['volume_byte'] // 512 + int.from_bytes(boot[14:16], 'little') + boot[16] * int.from_bytes(boot[22:24], 'little')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixtures-results', type=Path, help='reuse immutable fixture images from a recorded disk run')
    args = parser.parse_args()
    parent = ROOT / 'build/normal-fs'
    parent.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='run-', dir=parent))
    inputs = [*sorted((ROOT / 'src').rglob('*.zig')), *sorted((ROOT / 'src/storage').glob('*.c')),
        *sorted((ROOT / 'include').glob('*.h')), ROOT / 'tools/normal_fs_build.py', Path(__file__),
        ROOT / 'probes/normal-fs/check.c', ROOT / 'src/platform/native/fatfs_card.c', ROOT / 'src/platform/native/fatfs_disk.c']
    source_hashes = {str(p.relative_to(ROOT)): sha(p) for p in inputs}
    report = {'schema': 1, 'passed': False, 'evidence': 'hosted real normal-service path with deterministic UI/SDIO turns',
        'hardware_executed': False, 'physical_timing_measured': False, 'whole_stack_qualified': False,
        'sources': source_hashes, 'host': platform.platform(), 'sanitizers': ['address', 'undefined'],
        'fixtures': [], 'negative_controls': []}
    def save():
        (work / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    save()
    objects, source = build(work / 'host', native=False)
    executable = link(work / 'host', objects)
    report['upstream'] = {p.name: sha(p) for p in source.iterdir() if p.is_file()}
    if args.fixtures_results:
        fixtures = [(Path(row['image']), row['fixture']) for row in json.loads(args.fixtures_results.read_text())['fixtures']]
    else:
        cc = shlex.split(os.environ.get('CC', 'cc'))
        writer = work / 'writer'
        execute([*cc, '-std=c11', '-O1', '-g', '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined',
            '-fno-omit-frame-pointer', '-DNIHOS_FIXTURE_WRITER=1', '-I' + str(ROOT / 'probes/fatfs-disk'), '-I' + str(source),
            ROOT / 'probes/fatfs-disk/make_fixture.c', ROOT / 'probes/fatfs-disk/host_disk.c', source / 'ff.c', source / 'ffunicode.c', '-o', writer])
        fixtures = []
        for name in FORMATS:
            image = work / (name + '.img')
            fixtures.append((image, json.loads(execute([writer, image, name]).stdout)))
    if {f['format'] for _, f in fixtures} != set(FORMATS):
        raise RuntimeError('all five fixture formats required')
    for image, fixture in fixtures:
        before = sha(image)
        row = {'format': fixture['format'], 'fixture': fixture, 'image': str(image), 'sha256_before': before, 'cases': []}
        for mode in MODES:
            command = [executable, image, mode]
            if mode == 'empty-root':
                command.append(root_sector(image, fixture))
            observed = json.loads(execute(command).stdout)
            if not observed['passed']:
                raise RuntimeError('unsuccessful observation')
            row['cases'].append(observed)
        row['sha256_after'] = sha(image)
        if row['sha256_after'] != before:
            raise RuntimeError('service changed fixture: ' + str(image))
        report['fixtures'].append(row)
        save()
    # Change only an isolated copy. Each injected lifetime defect must be
    # exposed by the same end-to-end test, not an assertion of its own code.
    mutants = (
        ('stale-submit', 'normal_fs.zig', 'if (status(s) != .mounted or s.host_generation != host.generation()) return 0;',
            'if (status(s) != .mounted) return 0;', 'generation'),
        ('unproved-cache-handoff', 'shared_sdmmc.zig', 'if (released != 1) return false;',
            'if (released != 1) return true;', 'quarantine'),
    )
    for name, file, old, new, mode in mutants:
        mutant = work / name
        sources = mutant / 'source'
        sources.mkdir(parents=True)
        for item in ('normal_fs.zig', 'normal_fs_abi.zig', 'normal_fs_test_hooks.zig', 'shared_sdmmc.zig', 'shared_sdmmc_abi.zig'):
            shutil.copyfile(ROOT / 'src/platform/native' / item, sources / item)
        path = sources / file
        text = path.read_text()
        if text.count(old) != 1:
            raise RuntimeError('ambiguous negative control: ' + name)
        path.write_text(text.replace(old, new))
        mutant_objects, _ = build(mutant, native=False, runtime_source=sources / 'normal_fs.zig')
        broken = link(mutant, mutant_objects)
        observed = execute([broken, fixtures[0][0], mode], success=False)
        if not observed.returncode or 'normal FS check line' not in observed.stderr:
            raise RuntimeError('negative control not detected: ' + name)
        report['negative_controls'].append({'name': name, 'mode': mode, 'rejected': True,
            'source_sha256': sha(path), 'exit_code': observed.returncode, 'reason': observed.stderr.splitlines()[0]})
        save()
    native_objects, _ = build(work / 'rv32', native=True)
    report['rv32_objects'] = {p.name: {'sha256': sha(p), 'bytes': p.stat().st_size} for p in native_objects}
    if any(sha(ROOT / name) != value for name, value in source_hashes.items()):
        raise RuntimeError('sources changed during capture')
    report['case_count'] = sum(len(row['cases']) for row in report['fixtures'])
    report['passed'] = True
    save()
    print(json.dumps({'passed': True, 'cases': report['case_count'], 'negative_controls': len(mutants), 'report': str(work / 'results.json')}))


if __name__ == '__main__':
    main()
