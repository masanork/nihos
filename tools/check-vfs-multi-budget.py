#!/usr/bin/env python3
"""RV32 compile-only sizes; no storage admission or physical qualification."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import shlex
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ('src/vfs_multi_layout_probe.zig', 'src/vfs_multi_probe_module.zig', 'src/fs/vfs_multi_writer.zig',
           'src/fs/vfs.zig', 'src/fs/io_leases.zig', 'src/kernel/spsc_ring.zig',
           'src/platform/native/normal_fs.zig', 'src/platform/native/normal_fs_abi.zig',
           'src/platform/native/normal_fs_test_hooks.zig', 'src/platform/native/shared_sdmmc.zig',
           'src/platform/native/shared_sdmmc_abi.zig', 'src/platform/native/sram_pool.h',
           'probes/normal-fs/pool_alignment_check.c', 'tools/normal_fs_build.py',
           'tools/check-vfs-multi-budget.py')


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def sizes(path):
    data = Path(path).read_bytes()
    if data[:7] != b'\x7fELF\x01\x01\x01' or struct.unpack_from('<H', data, 18)[0] != 243:
        raise ValueError('expected little-endian RV32 ELF object')
    shoff = struct.unpack_from('<I', data, 32)[0]
    stride, count = struct.unpack_from('<HH', data, 46)
    sections = [struct.unpack_from('<10I', data, shoff + i * stride) for i in range(count)]
    found = {}
    for row in sections:
        if row[1] != 2:
            continue
        strings = sections[row[6]]
        names = data[strings[4]:strings[4] + strings[5]]
        for offset in range(row[4], row[4] + row[5], row[9]):
            name_offset, _, size, _, _, _ = struct.unpack_from('<IIIBBH', data, offset)
            end = names.index(0, name_offset)
            name = names[name_offset:end].decode('ascii', errors='replace')
            if name.startswith(('nih_multi_', 'nih_normal_fs_state_', 'nih_normal_fs_projection_')):
                if name in found:
                    raise ValueError('duplicate layout symbol: ' + name)
                found[name] = size
    return found


def main():
    os.chdir(ROOT)
    hashes = {path: sha(ROOT / path) for path in SOURCES}
    source = (ROOT / 'src/platform/native/normal_fs.zig').read_text()
    allocation = ('nih_base_sram_take(2, 65536, 65536, &lease)',
                  'nih_base_sram_take_aligned(2, 65536, 65536, @alignOf(State), &lease)')
    if not any(item in source for item in allocation) or '@sizeOf(State) > 65536' not in source:
        raise ValueError('normal FS quota changed; review the comparison')
    zig = subprocess.check_output(['sh', str(ROOT / 'tools/bootstrap-zig.sh')], text=True).strip()
    # normal_fs_build consumes the same verified pinned FatFs source as native.
    subprocess.run([sys.executable, str(ROOT / 'tools/bootstrap-fatfs.py')], check=True, stdout=subprocess.DEVNULL)
    with tempfile.TemporaryDirectory(prefix='vfs-multi-budget-') as folder:
        work = Path(folder)
        obj = work / 'multi.o'
        subprocess.run([zig, 'build-obj', '-target', 'riscv32-freestanding-none',
            '-mcpu=generic_rv32+m+a+c+zicsr+zifencei', '-O', 'ReleaseSafe',
            str(ROOT / 'src/vfs_multi_layout_probe.zig'), '-femit-bin=' + str(obj)], check=True)
        values = sizes(obj)
        copy = work / 'source'
        copy.mkdir()
        for filename in ('normal_fs.zig', 'normal_fs_abi.zig', 'normal_fs_test_hooks.zig', 'shared_sdmmc.zig', 'shared_sdmmc_abi.zig'):
            shutil.copyfile(ROOT / 'src/platform/native' / filename, copy / filename)
        # Zig assigns each source file to one module. The projection uses an
        # isolated copy to avoid sharing vfs.zig with the real storage module.
        probe = work / 'probe'
        for name in ('vfs_multi_probe_module.zig', 'fs/vfs_multi_writer.zig',
                     'fs/vfs.zig', 'fs/io_leases.zig', 'kernel/spsc_ring.zig'):
            (probe / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / 'src' / name, probe / name)
        start = source.index('const State = struct {')
        end = source.index('\n};\ncomptime {', start) + 3
        projection = source[start:end].replace('const State = struct {', 'const ProjectedState = struct {', 1)
        old_fields = '    owner: Owner,\n    queues: rpc.Queues,\n    frames: rpc.ClientFrames,\n    notifications: rpc.Notifications,'
        if projection.count(old_fields) != 1:
            raise ValueError('normal FS ownership fields changed; review projection')
        projection = projection.replace(old_fields, '''    owner: @import("multi_probe").multi.Service(Backend),
    queues: [2]@import("multi_probe").multi.Queues,
    frames: ProjectionFrames,''')
        with (copy / 'normal_fs.zig').open('a') as out:
            out.write('\npub export var nih_normal_fs_state_size: [@sizeOf(State)]u8 = undefined;\n')
            out.write('pub export var nih_normal_fs_state_alignment: [@alignOf(State)]u8 = undefined;\n')
            out.write('const ProjectionFrames = struct { request: @import("multi_probe").multi.Request, response: @import("multi_probe").multi.Response };\n')
            out.write(projection + '\n')
            out.write('pub export var nih_normal_fs_projection_size: [@sizeOf(ProjectedState)]u8 = undefined;\n')
            out.write('pub export var nih_normal_fs_projection_alignment: [@alignOf(ProjectedState)]u8 = undefined;\n')
            out.write('pub export var nih_normal_fs_projection_frames: [@sizeOf(ProjectionFrames)]u8 = undefined;\n')
        sys.path.insert(0, str(ROOT / 'tools'))
        from normal_fs_build import build
        previous = {name: os.environ.get(name) for name in ('NIHOS_NATIVE_SQLD', 'NIHOS_NATIVE_SQLD_PROVISION_CID')}
        os.environ['NIHOS_NATIVE_SQLD'] = '1'
        os.environ['NIHOS_NATIVE_SQLD_PROVISION_CID'] = '0'
        try:
            objects, _ = build(work / 'normal', native=True, runtime_source=copy / 'normal_fs.zig',
                               multi_probe_source=probe / 'vfs_multi_probe_module.zig')
        finally:
            for name, value in previous.items():
                if value is None:
                    del os.environ[name]
                else:
                    os.environ[name] = value
        values.update(sizes(objects[0]))
        pool_probe = work / 'pool-alignment'
        cc = shlex.split(os.environ.get('CC', 'cc'))
        subprocess.run([*cc, '-std=c11', '-Wall', '-Wextra', '-Werror',
            '-I' + str(ROOT / 'src/platform/native'), str(ROOT / 'probes/normal-fs/pool_alignment_check.c'),
            '-o', str(pool_probe)], check=True)
        alignment = json.loads(subprocess.check_output([str(pool_probe)], text=True))
        expected = ('nih_multi_request_size', 'nih_multi_response_size', 'nih_multi_queues_size',
                    'nih_multi_owner_size', 'nih_multi_issuer_size', 'nih_multi_combined_size',
                    'nih_multi_combined_alignment', 'nih_normal_fs_state_size', 'nih_normal_fs_state_alignment',
                    'nih_normal_fs_projection_size', 'nih_normal_fs_projection_alignment', 'nih_normal_fs_projection_frames')
        if set(values) != set(expected) or not all(values.values()):
            raise ValueError('missing or unexpected layout symbols: ' + repr(values))
        align = values['nih_multi_combined_alignment']
        old = values['nih_normal_fs_state_size']
        extra = values['nih_multi_combined_size']
        if align & (align - 1):
            raise ValueError('invalid combined alignment')
        additive = ((old + align - 1) // align) * align + extra
        quota = 65536
        if any(sha(ROOT / path) != digest for path, digest in hashes.items()):
            raise ValueError('source changed while measuring')
        print(json.dumps({'scope': 'RV32 type layout only; no linked integration or admission',
            'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
            'zig_version': subprocess.check_output([zig, 'version'], text=True).strip(),
            'selected_source_sha256': hashes, 'symbols_bytes': values, 'normal_parent_bytes': quota,
            'normal_parent_unused_bytes': quota - old,
            'additive_combined_bytes': additive, 'additive_over_quota_bytes': max(0, additive - quota),
            'additive_fits_parent': additive <= quota,
            'projected_replacement_bytes': values['nih_normal_fs_projection_size'],
            'projected_replacement_fits_parent': values['nih_normal_fs_projection_size'] <= quota,
            'projected_parent_headroom_bytes': quota - values['nih_normal_fs_projection_size'],
            'pool_alignment_contract_bytes': 64,
            'synthetic_legal_pool_allocation': alignment,
            'normal_state_requires_more_alignment': values['nih_normal_fs_state_alignment'] > 64,
            'projection_scope': 'type substitution only, retaining one UI request and response frame; not executable integration',
            'excluded': ['persistent external issuer and additional client frames and stacks',
                         'changes needed for runtime integration, notifications and revocation',
                         'runtime fragmentation, concurrent owners, DMA/cache and device tests']}, indent=2))


if __name__ == '__main__':
    main()
