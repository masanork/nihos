#!/usr/bin/env python3
"""Guarded FatFs/VFS/RPC and broker lifetime tests; RV32 compile only, no device."""
import json
from pathlib import Path
import runpy
import struct
import subprocess
import platform
import os
import shlex

ROOT = Path(__file__).resolve().parents[1]
BASE = runpy.run_path(str(ROOT / 'tools/check-fatfs-disk.py'))
run, sha = BASE['run'], BASE['sha']
PROBE = ROOT / 'probes/fatfs-disk'


def symbol_size(path, wanted):
    data = path.read_bytes()
    if data[:7] != b'\x7fELF\x01\x01\x01':
        raise RuntimeError('Expected compiler-produced ELF32 little endian')
    shoff = struct.unpack_from('<I', data, 32)[0]
    stride, count = struct.unpack_from('<HH', data, 46)
    sections = [struct.unpack_from('<10I', data, shoff + i * stride) for i in range(count)]
    for row in sections:
        if row[1] != 2:
            continue
        strings = sections[row[6]]
        names = data[strings[4]:strings[4] + strings[5]]
        for offset in range(row[4], row[4] + row[5], row[9]):
            name, _, size, _, _, _ = struct.unpack_from('<IIIBBH', data, offset)
            if names[name:names.index(0,name)] == wanted:
                return size
    raise RuntimeError('Missing layout symbol: ' + repr(wanted))


def main():
    inputs = [ROOT / 'include/nihos_fatfs_backend.h', ROOT / 'src/storage/fatfs_backend.c',
              ROOT / 'include/nihos_fatfs_card.h', ROOT / 'src/platform/native/fatfs_card.c',
              ROOT / 'src/fs/fatfs_backend.zig', ROOT / 'src/fs/vfs.zig', ROOT / 'src/fs/vfs_test.zig',
              ROOT / 'src/fs/io_leases.zig', ROOT / 'src/root.zig', ROOT / 'tools/check-fatfs-backend.py',
              ROOT / 'src/storage_vfs.zig', ROOT / 'src/fs/vfs_rpc.zig', ROOT / 'src/fs/vfs_rpc_test.zig',
              ROOT / 'src/fs/vfs_memory.zig', ROOT / 'src/fs/io_stop.zig', ROOT / 'src/kernel/spsc_ring.zig',
              ROOT / 'src/fs/sdmmc_owner.zig', ROOT / 'src/fs/sdmmc_owner_test.zig',
              ROOT / 'src/soc/esp32p4/sdmmc.zig',
              ROOT / 'src/kernel/memory_broker.zig', ROOT / 'src/kernel/page_pool.zig', ROOT / 'src/kernel/development_memory.zig',
              ROOT / 'docs/planning/tab5-development-profile.json',
              ROOT / 'tools/run-static-analysis.sh', ROOT / '.github/workflows/ci.yml']
    source_hashes = {str(p.relative_to(ROOT)): sha(p) for p in inputs}
    base_path = Path(run(['python3', ROOT / 'tools/check-fatfs-disk.py'], timeout=120).strip())
    work = base_path.parent
    base = json.loads(base_path.read_text())
    source = work / 'fatfs/source'
    zig = run(['sh', ROOT / 'tools/bootstrap-zig.sh']).strip()
    host_target = []
    if platform.system() == 'Darwin':
        arch = {'arm64': 'aarch64', 'x86_64': 'x86_64'}[platform.machine()]
        host_target = ['-target', arch + '-macos.' + run(['xcrun', '--sdk', 'macosx', '--show-sdk-version']).strip()]
    library = work / 'vfs-check.a'
    run([zig, 'build-lib', *host_target, '-O', 'ReleaseSafe', '--dep', 'storage_vfs', '--dep', 'sdmmc',
         '-Mroot=' + str(PROBE / 'host_library.zig'), *host_target, '-O', 'ReleaseSafe',
         '-Mstorage_vfs=' + str(ROOT / 'src/storage_vfs.zig'), *host_target, '-O', 'ReleaseSafe',
         '-Msdmmc=' + str(ROOT / 'src/soc/esp32p4/sdmmc.zig'), '-femit-bin=' + str(library)])
    cc = shlex.split(os.environ.get('CC', 'cc'))
    binary = work / 'backend-check'
    flags = ['-std=c11', '-O1', '-g', '-Wall', '-Wextra', '-Werror',
             '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
             '-I' + str(ROOT / 'include'), '-I' + str(PROBE), '-I' + str(source)]
    run([*cc, *flags, PROBE / 'backend_check.c', ROOT / 'src/storage/fatfs_backend.c',
         ROOT / 'src/platform/native/fatfs_card.c',
         ROOT / 'src/storage/fatfs_disk.c', ROOT / 'src/storage/fatfs_volume.c',
         ROOT / 'src/platform/native/fatfs_disk.c',
         PROBE / 'safety.c', source / 'ffunicode.c', library, '-o', binary])
    card_binary = work / 'card-check'
    run([*cc, *flags, PROBE / 'card_check.c', ROOT / 'src/platform/native/fatfs_card.c',
         ROOT / 'src/storage/fatfs_volume.c', ROOT / 'src/storage/fatfs_backend.c',
         ROOT / 'src/storage/fatfs_disk.c', ROOT / 'src/platform/native/fatfs_disk.c',
         PROBE / 'safety.c', source / 'ffunicode.c', '-o', card_binary])
    report = {'schema': 1, 'passed': False, 'evidence': 'host guarded FatFs, VFS/RPC and actual broker lifetime integration; RV32 compile only',
              'hardware_executed': False, 'firmware_linked': False,
              'c_sanitizers': ['address', 'undefined'], 'zig_mode': 'ReleaseSafe',
              'upstream_sha256': base['upstream_sha256'],
              'disk_contract': {'observed': base['contract'], 'writable_config_rejected': base['writable_config_rejected'],
                                'forbidden_write_symbols': base['forbidden_write_symbols']},
              'volume_contract': base['volume_contract'],
              'volume_negative_controls': base['volume_negative_controls'],
              'card_pipeline': [],
              'base_results': str(base_path), 'base_results_sha256': sha(base_path), 'cases': [], 'fixtures': []}
    def save():
        (work / 'backend-results.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    def probe(row, name, mode, target='Memo.txt', patch=None):
        args = [binary, row['image'], row['fixture']['volume_byte'] // 512, mode, target]
        if patch is not None:
            args += [patch[0], patch[1].hex()]
        observed = json.loads(run(args, timeout=30))
        report['cases'].append({'name': row['fixture']['format'] + ':' + name, 'observed': observed})
        save()
    save()
    def fat_entry(image, fixture, cluster, replacement=None):
        fmt = fixture['fs_type']
        width = 2 if fmt in (1, 2) else 4
        offset = fixture['fat_byte'] + (cluster + cluster // 2 if fmt == 1 else cluster * width)
        with image.open('rb') as stream:
            stream.seek(offset)
            raw = int.from_bytes(stream.read(width), 'little')
        if replacement is None:
            return ((raw >> 4 if cluster % 2 else raw) & 0xfff) if fmt == 1 else raw & (0xffff if fmt == 2 else 0x0fffffff if fmt == 3 else 0x7fffffff)
        if fmt == 1:
            replacement = ((raw & 15) | ((replacement & 0xfff) << 4)) if cluster % 2 else ((raw & 0xf000) | (replacement & 0xfff))
        return offset, replacement.to_bytes(width, 'little')
    for row in base['fixtures']:
        fixture, image = row['fixture'], Path(row['image'])
        before = sha(image)
        report['card_pipeline'].append({'format': fixture['format'], 'observed':json.loads(run([card_binary,image]))})
        probe(row, 'identity-and-admission', 'normal', fixture['alias'] or 'LONG FILENAME FOR ALIAS.TXT')
        for mode in ('vfs', 'selected-vfs', 'io', 'removed'):
            probe(row, mode, mode)
        for mode in ('rpc-cancel', 'rpc-exit', 'card-rpc-cancel', 'card-rpc-exit',
                     'card-rpc-transport-cancel', 'card-rpc-transport-remove', 'card-rpc-idle-remove',
                     'card-rpc-linked-cancel', 'card-rpc-linked-exit'):
            probe(row, mode, mode)
        if fixture['fs_type'] == 4:
            probe(row, 'rpc-large', 'rpc-large')
        first = fixture['fragment_first_cluster']
        second = fat_entry(image, fixture, first)
        for label, cluster, replacement in (
                ('self-cycle', first, first), ('two-node-cycle', second, first),
                ('short-chain', first, {1: 0xfff, 2: 0xffff, 3: 0x0fffffff, 4: 0xffffffff}[fixture['fs_type']])):
            probe(row, label, 'corrupt', 'fragment.bin', fat_entry(image, fixture, cluster, replacement))
        if fixture['root_cluster']:
            probe(row, 'root-cycle', 'corrupt', 'Memo.txt', fat_entry(image, fixture, fixture['root_cluster'], fixture['root_cluster']))
        if fixture['fs_type'] != 4:
            child = fixture['child_cluster']
            probe(row, 'parent-cycle', 'corrupt', '教材/漢字𠮷.txt', fat_entry(image, fixture, child, child))
            with image.open('rb') as stream:
                stream.seek(fixture['child_entry_byte'])
                entry = bytearray(stream.read(32))
            entry[20:22] = struct.pack('<H', fixture['root_cluster'] >> 16)
            entry[26:28] = struct.pack('<H', fixture['root_cluster'] & 0xffff)
            probe(row, 'ancestor-alias', 'corrupt', '教材/Memo.txt', (fixture['child_entry_byte'], entry))
        else:
            probe(row, 'large-guarded-offsets', 'large')
            offset = fixture['data_byte'] + (fixture['root_cluster'] - 2) * fixture['cluster_bytes']
            with image.open('rb') as stream:
                stream.seek(offset)
                entries = stream.read(fixture['cluster_bytes'])
            for position in range(0, len(entries) - 64, 32):
                if entries[position] != 0x85 or not entries[position + 4] & 0x10 or struct.unpack_from('<I', entries, position + 52)[0] != fixture['child_cluster']:
                    continue
                length = (entries[position + 1] + 1) * 32
                block = bytearray(entries[position:position + length])
                struct.pack_into('<I', block, 52, fixture['root_cluster'])
                checksum = 0
                for index, byte in enumerate(block):
                    if index not in (2, 3):
                        checksum = (((checksum >> 1) | ((checksum & 1) << 15)) + byte) & 0xffff
                struct.pack_into('<H', block, 2, checksum)
                probe(row, 'ancestor-alias', 'corrupt', '教材/Memo.txt', (offset + position, block))
                break
            else:
                raise RuntimeError('exFAT fixture child directory not found')
        probe(row, 'boot-signature', 'bad-volume', patch=(fixture['volume_byte'] + 510, bytes(2)))
        length_offset = 72 if fixture['fs_type'] == 4 else 32 if fixture['fs_type'] == 3 else 19
        width = 8 if fixture['fs_type'] == 4 else 4 if fixture['fs_type'] == 3 else 2
        length = fixture['image_bytes'] // 512 + 1 if width != 2 else 0xffff
        probe(row, 'volume-bounds', 'bad-volume', patch=(fixture['volume_byte'] + length_offset, length.to_bytes(width, 'little')))
        after = sha(image)
        if before != after:
            raise RuntimeError('Input image changed: ' + str(image))
        report['fixtures'].append({'format': fixture['format'], 'sha256_before': before, 'sha256_after': after})
    headers = ROOT / '.tools/zig-0.17.0/lib/libc/include'
    target = [zig, 'cc', '-target', 'riscv32-freestanding-none', '-mcpu=generic_rv32+m+a+c+zicsr+zifencei',
              '-ffreestanding', '-O2', '-std=c11', '-Wall', '-Wextra', '-Werror',
              '-isystem', headers / 'riscv32-linux-musl', '-isystem', headers / 'generic-musl',
              '-isystem', headers / 'riscv-linux-any', '-I' + str(ROOT / 'include'),
              '-I' + str(PROBE), '-I' + str(source), '-c']
    report['rv32_objects'] = {}
    for path in (ROOT / 'src/storage/fatfs_backend.c', ROOT / 'src/platform/native/fatfs_card.c', PROBE / 'safety.c', source / 'ffunicode.c'):
        output = work / ('rv32-' + path.stem + '.o')
        run([*target, path, '-o', output])
        report['rv32_objects'][str(path.relative_to(ROOT))] = {'sha256': sha(output), 'bytes': output.stat().st_size}
    native = work / 'rv32-vfs.o'
    module_target = ['-target', 'riscv32-freestanding-none', '-mcpu=generic_rv32+m+a+c+zicsr+zifencei', '-O', 'ReleaseSafe']
    run([zig, 'build-obj', *module_target, '--dep', 'storage_vfs', '-Mroot=' + str(PROBE / 'vfs_rv32.zig'),
         *module_target, '-Mstorage_vfs=' + str(ROOT / 'src/storage_vfs.zig'), '-femit-bin=' + str(native)])
    report['rv32_objects']['VFS/RPC and broker parent instantiation'] = {'sha256': sha(native), 'bytes': native.stat().st_size}
    # Exact opaque session size from a compiler-produced ELF symbol; no target
    # code is executed and ELF file/debug bytes are not counted as workspace.
    layout_source, layout_object = work / 'backend-layout.c', work / 'backend-layout.o'
    layout_source.write_text('#include "' + str(ROOT / 'src/storage/fatfs_backend.c') + '"\nchar nih_backend_layout[sizeof(nih_fatfs_backend)];\n')
    run([*target, layout_source, '-o', layout_object])
    report['rv32_workspace_bytes'] = {'disk': base['rv32_workspace_bytes'],
        'backend': symbol_size(layout_object, b'nih_backend_layout'),
        'vfs_one_mount_32_handles': symbol_size(native, b'nih_fatfs_vfs_layout')}
    card_layout_source, card_layout_object = work / 'card-layout.c', work / 'card-layout.o'
    card_layout_source.write_text('#include "' + str(ROOT / 'src/platform/native/fatfs_card.c') + '"\nchar nih_card_layout[sizeof(nih_fatfs_card)];\n')
    run([*target, card_layout_source, '-o', card_layout_object])
    report['rv32_card_workspace_bytes'] = symbol_size(card_layout_object,b'nih_card_layout')
    report['rpc_layout_bytes'] = {name: symbol_size(native, symbol.encode()) for name,symbol in (
        ('owner_including_vfs', 'nih_fatfs_rpc_layout'), ('queues', 'nih_fatfs_queues_layout'),
        ('notifications_internal', 'nih_fatfs_notifications_layout'), ('request', 'nih_fatfs_request_layout'),
        ('response', 'nih_fatfs_response_layout'), ('parent_coordinator', 'nih_fatfs_parent_control_layout'),
        ('client_frames', 'nih_fatfs_client_frames_layout'))}
    at = 0
    offsets = {}
    for name, size in (('disk', report['rv32_workspace_bytes']['disk']), ('backend', report['rv32_workspace_bytes']['backend']),
                       ('endpoint', report['rpc_layout_bytes']['owner_including_vfs']), ('queues', report['rpc_layout_bytes']['queues'])):
        at = (at + 127) // 128 * 128
        offsets[name] = at
        at += size
    if at > 65536:
        raise RuntimeError('RPC parent exceeds its admitted allocation')
    report['rpc_parent'] = {'offsets': offsets, 'used': at, 'charged': 65536,
                            'client_frames_charged_separately': 8192, 'policy': 'unchanged generated development profile'}
    card_at = 0
    for size in (report['rv32_card_workspace_bytes'],8,report['rpc_layout_bytes']['owner_including_vfs'],report['rpc_layout_bytes']['queues']):
        card_at=(card_at+127)//128*128+size
    if card_at>65536: raise RuntimeError('Card RPC parent exceeds admitted allocation')
    report['card_rpc_parent'] = {'used':card_at,'charged':65536,'client_frames_charged_separately':8192,
                                 'controller_dma_staging':'unchanged resident SRAM'}
    report['sources'] = {**base['sources'], **source_hashes}
    if any(sha(ROOT / name) != expected for name, expected in report['sources'].items()):
        raise RuntimeError('Source changed during Backend/VFS qualification')
    report['limitations'] = ['Host synchronous callback replaces native DMA implementation; no hardware execution',
        'No native firmware link or final layout/stack/memory admission',
        'Volume root only; selected-vfs cases use superfloppy/MBR admission; GPT/extended layouts are rejected',
        'Single owner, immutable mounted media, 16 open files plus one staged guarded lookup',
        'RPC exit/cancel events are injected into a synchronous host callback; no native scheduler/wakeup or IRQ hookup',
        'Read cancellation waits for backend quiescent return and scrubs the reply; it does not abort the controller',
        'Full native placement, stack/call-graph admission, persistent SQLite, writes and power-loss recovery remain separate gates']
    report['passed'] = True
    save()
    print(work / 'backend-results.json')


if __name__ == '__main__':
    main()
