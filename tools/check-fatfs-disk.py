#!/usr/bin/env python3
"""Host-only fenced diskio contract + real FatFs images; RV32 compile, no device."""
import hashlib
import json
import os
from pathlib import Path
import platform
import runpy
import shlex
import shutil
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / 'probes/fatfs-disk'


def sha(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(data)
    return value.hexdigest()


def run(command, timeout=120):
    env = os.environ.copy()
    env['ASAN_OPTIONS'] = 'abort_on_error=1:detect_leaks=' + ('0' if platform.system() == 'Darwin' else '1')
    env['UBSAN_OPTIONS'] = 'halt_on_error=1:print_stacktrace=1'
    result = subprocess.run([str(p) for p in command], capture_output=True, text=True,
                            timeout=timeout, env=env)
    if result.returncode or result.stderr:
        raise RuntimeError(f'{command}: exit {result.returncode}\n{result.stdout}\n{result.stderr}')
    return result.stdout


def main():
    inputs = [ROOT / 'include/nihos_fatfs_disk.h', ROOT / 'include/nihos_fatfs_volume.h',
              ROOT / 'include/nihos_storage_io.h',
              ROOT / 'src/storage/fatfs_disk.c', ROOT / 'src/storage/fatfs_volume.c',
              ROOT / 'src/platform/native/fatfs_disk.c', ROOT / 'tools/bootstrap-fatfs.py',
              ROOT / 'tools/check-fatfs-disk.py', ROOT / 'provenance.toml', *sorted(PROBE.glob('*'))]
    source_hashes = {str(p.relative_to(ROOT)): sha(p) for p in inputs if p.is_file()}
    parent = ROOT / 'build/fatfs-disk'
    parent.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='run-', dir=parent))
    bootstrap = runpy.run_path(str(ROOT / 'tools/bootstrap-fatfs.py'))
    cache = work / 'fatfs'
    cache.mkdir()
    # Seed an isolated verified cache: never reconstruct another session's
    # upstream sources in the shared .tools directory.
    for name, _, expected in bootstrap['INPUTS']:
        cached = ROOT / '.tools/fatfs-r016-p2' / name
        if cached.is_file() and sha(cached) == expected:
            shutil.copyfile(cached, cache / name)
    source = bootstrap['bootstrap'](cache)
    cc = shlex.split(os.environ.get('CC', 'cc'))
    flags = ['-std=c11', '-O1', '-g', '-Wall', '-Wextra', '-Werror',
             '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
             f'-I{ROOT / "include"}', f'-I{PROBE}', f'-I{source}']
    writer, reader = work / 'writer', work / 'reader'
    run([*cc, *flags, '-DNIHOS_FIXTURE_WRITER=1', PROBE / 'make_fixture.c',
         PROBE / 'host_disk.c', source / 'ff.c', source / 'ffunicode.c', '-o', writer])
    run([*cc, *flags, PROBE / 'check_disk.c', ROOT / 'src/storage/fatfs_disk.c',
         ROOT / 'src/storage/fatfs_volume.c',
         ROOT / 'src/platform/native/fatfs_disk.c', source / 'ff.c', source / 'ffunicode.c', '-o', reader])
    volume = work / 'volume-check'
    run([*cc, *flags, PROBE / 'check_volume.c', ROOT / 'src/storage/fatfs_volume.c', '-o', volume])
    report = {'schema': 1, 'evidence': 'host-only FatFs diskio integration and RV32 compile',
              'passed': False,
              'hardware_executed': False, 'firmware_linked': False,
              'host': platform.platform(), 'compiler': run([*cc, '--version']).splitlines()[0],
              'sanitizers': ['address', 'undefined'], 'fixtures': [],
              'upstream_sha256': {p.name: sha(p) for p in sorted(source.iterdir())},
              'contract': json.loads(run([reader])), 'volume_contract': json.loads(run([volume]))}
    report['volume_negative_controls'] = []
    original = (ROOT / 'src/storage/fatfs_volume.c').read_text()
    mutants = (
        ('partition-range', 'parts[i].count > sectors - parts[i].first', '0'),
        ('overlap', 'if (parts[j].count &&', 'if (0 &&'),
        ('ambiguity', 'if (++found > 1) return NIH_VOLUME_AMBIGUOUS;', '++found;'),
        ('declared-length', 'v->count = total;', 'v->count = container;'),
        ('exfat-shift', 'p[109] > 15 || ', ''),
    )
    for name, old, new in mutants:
        if original.count(old) != 1:
            raise RuntimeError('Ambiguous volume negative control: ' + name)
        mutated, executable = work / ('mutant-' + name + '.c'), work / ('mutant-' + name)
        mutated.write_text(original.replace(old, new))
        run([*cc, *flags, PROBE / 'check_volume.c', mutated, '-o', executable])
        outcome = subprocess.run([executable], capture_output=True, text=True, timeout=15,
                                 env={**os.environ, 'UBSAN_OPTIONS': 'halt_on_error=1:print_stacktrace=1',
                                      'ASAN_OPTIONS': 'abort_on_error=1:detect_leaks=0'})
        if outcome.returncode == 0 or not outcome.stderr:
            raise RuntimeError('Volume regression did not reject mutant: ' + name)
        report['volume_negative_controls'].append({'case': name, 'rejected': True,
            'source_sha256': sha(mutated), 'exit_code': outcome.returncode,
            'reason': outcome.stderr.splitlines()[0]})
    def save():
        (work / 'results.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    save()
    symbols = {line.split()[-1].lstrip('_') for line in run(['nm', reader]).splitlines() if line.split()}
    forbidden = sorted(symbols & {'f_write', 'f_mkfs', 'f_unlink', 'f_rename', 'f_truncate', 'f_sync', 'f_mkdir'})
    if forbidden:
        raise RuntimeError('Read-only probe links write APIs: ' + repr(forbidden))
    report['forbidden_write_symbols'] = forbidden
    negative = subprocess.run([*cc, *flags, '-DNIHOS_FIXTURE_WRITER=1', '-c',
                               str(ROOT / 'src/storage/fatfs_disk.c'), '-o', str(work / 'forbidden-writer.o')],
                              capture_output=True, text=True, timeout=30)
    if not negative.returncode or 'FatFs disk bridge requires read-only' not in negative.stderr:
        raise RuntimeError('Writable FatFs configuration was not rejected at compile time')
    report['writable_config_rejected'] = True
    for name in ('fat12', 'fat16', 'fat32', 'mbr-fat32', 'exfat'):
        image = work / (name + '.img')
        fixture = json.loads(run([writer, image, name]))
        before = sha(image)
        first = fixture['volume_byte'] // 512
        result = json.loads(run([reader, image, first, fixture['fs_type']], timeout=30))
        after = sha(image)
        if before != after:
            raise RuntimeError('Fixture was changed: ' + name)
        report['fixtures'].append({'fixture': fixture, 'sha256_before': before, 'sha256_after': after,
                                   'image': str(image), 'observed': result})
        save()
    zig = run(['sh', ROOT / 'tools/bootstrap-zig.sh']).strip()
    headers = ROOT / '.tools/zig-0.17.0/lib/libc/include'
    target = [zig, 'cc', '-target', 'riscv32-freestanding-none',
              '-mcpu=generic_rv32+m+a+c+zicsr+zifencei', '-ffreestanding', '-O2',
              '-std=c11', '-Wall', '-Wextra', '-Werror',
              '-isystem', headers / 'riscv32-linux-musl', '-isystem', headers / 'generic-musl',
              '-isystem', headers / 'riscv-linux-any',
              f'-I{ROOT / "include"}', f'-I{PROBE}', f'-I{source}', '-c']
    report['rv32_objects'] = {}
    for path in (ROOT / 'src/storage/fatfs_disk.c', ROOT / 'src/platform/native/fatfs_disk.c',
                 ROOT / 'src/storage/fatfs_volume.c'):
        output = work / (path.parent.name + '-' + path.stem + '.o')
        run([*target, path, '-o', output])
        report['rv32_objects'][str(path.relative_to(ROOT))] = {'sha256': sha(output), 'bytes': output.stat().st_size}
    # Record exact RV32 workspace size from an ELF object, without executing it.
    size_source = work / 'workspace.c'
    size_source.write_text('#include "nihos_fatfs_disk.h"\nchar workspace[sizeof(nih_fatfs_disk)];\n')
    size_object = work / 'workspace.o'
    run([*target, size_source, '-o', size_object])
    data = size_object.read_bytes()
    shoff = struct.unpack_from('<I', data, 32)[0]
    entsize, count = struct.unpack_from('<HH', data, 46)
    bss = [struct.unpack_from('<10I', data, shoff + i * entsize) for i in range(count)]
    report['rv32_workspace_bytes'] = sum(row[5] for row in bss if row[1] == 8 and row[2] & 3 == 3)
    if any(sha(ROOT / name) != expected for name, expected in source_hashes.items()):
        raise RuntimeError('Source changed during disk/volume qualification')
    report['sources'] = source_hashes
    report['limitations'] = [
        'RV32 adapter object compile only; no final firmware placement, memory/stack admission or native FatFs execution',
        'Native callback depends on existing nih_storage_read lease pin and fatal handling of unproved DMA fences',
        'Valid image fixtures only; chain/identity shim from host VFS PR #3 is not linked here',
        'VFS backend, authenticated roots/handles, RPC and mount invalidation of cached FatFs objects remain unconnected',
        'Atomic disk_read publication does not imply atomic f_read or durable storage',
        'Read-only volume admission covers superfloppy/MBR primary only; GPT/extended layouts are rejected',
        'Volume probe requires a stable owner-held card/controller session through bind and mount; no hardware hot-swap detection',
        'No physical removal, clean power-on, writable filesystem, SQLite persistence or power-loss evidence']
    report['passed'] = True
    save()
    print(work / 'results.json')


if __name__ == '__main__':
    main()
