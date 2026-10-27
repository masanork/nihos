#!/usr/bin/env python3
"""Capture C object functions explicitly permitted in the SQLite Flash span."""
import hashlib
import json
from pathlib import Path
import re
import struct
import sys


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def functions(path):
    data = Path(path).read_bytes()
    if data[:7] != b'\x7fELF\x01\x01\x01':
        raise ValueError('expected ELF32 object')
    header = struct.unpack_from('<HHIIIIIHHHHHH', data, 16)
    if header[0] != 1 or header[1] != 243 or header[10] != 40:
        raise ValueError('expected relocatable RISC-V object')
    sections = [struct.unpack_from('<10I', data, header[5] + index * 40)
                for index in range(header[11])]
    result = set()
    for section in sections:
        if section[1] != 2:
            continue
        table = sections[section[6]]
        strings = data[table[4]:table[4] + table[5]]
        for position in range(section[4], section[4] + section[5], 16):
            name, _, _, info, _, target = struct.unpack_from('<IIIBBH', data, position)
            if name and info & 15 == 2 and 0 < target < len(sections):
                result.add(strings[name:strings.index(0, name)].decode())
    return sorted(result)


def main(directory, source, littlefs=None):
    objects = {name: {'sha256': sha(directory / name), 'functions': functions(directory / name)}
               for name in ('sql_sqlite3.o', 'sql_session.o', 'sql_vfs.o')}
    if littlefs is not None:
        for name in ('sql_lfs.o', 'sql_lfs_util.o', 'sql_lfs_reader.o', 'sql_storage_api.o'):
            objects[name] = {'sha256': sha(directory / name), 'functions': functions(directory / name)}
    if littlefs is not None and 'pub const storage_service = true;' in (directory / 'native_options.zig').read_text():
        objects['sql_storage_runtime.o'] = {'sha256': sha(directory / 'sql_storage_runtime.o'), 'functions': functions(directory / 'sql_storage_runtime.o')}
    if 'pub const broker = true;' in (directory / 'native_options.zig').read_text():
        objects['sql_broker_runtime.o'] = {'sha256': sha(directory / 'sql_broker_runtime.o'), 'functions': functions(directory / 'sql_broker_runtime.o')}
    profile_path = Path(__file__).resolve().parents[1] / 'src/kernel/size_pool.zig'
    matches = re.findall(r'sqlite_probe = Config\{ \.counts = \.\{([^}]+)\}', profile_path.read_text())
    if len(matches) != 1:
        raise ValueError('missing/ambiguous SQLite pool profile')
    quotas = [int(value.strip()) for value in matches[0].split(',') if value.strip()]
    if len(quotas) != 10 or not all(0 < value <= 65535 for value in quotas):
        raise ValueError('invalid pool quotas')
    result = {'schema': 1, 'pool_quotas': quotas, 'pool_profile_sha256': sha(profile_path),
              'purpose': 'explicit native SQLite Flash function allowlist; not attestation',
              'objects': objects, 'sqlite_source_sha256': sha(source / 'sqlite3.c'),
              'allowed_functions': sorted(set().union(*(set(item['functions']) for item in objects.values())))}
    if 'pub const broker = true;' in (directory / 'native_options.zig').read_text():
        root = Path(__file__).resolve().parents[1]
        result['broker'] = {'version': 2, 'profile_sha256': sha(root / 'docs/planning/tab5-development-profile.json'),
                            'runtime_sha256': sha(root / 'src/platform/native/broker_runtime.zig'),
                            'core_sha256': sha(root / 'src/kernel/memory_broker.zig'),
                            'sd_adapter_sha256': sha(root / 'src/platform/native/sdmmc_probe.zig')}
    if 'pub const cold_flash = true;' in (directory / 'native_options.zig').read_text():
        root = Path(__file__).resolve().parents[1]
        policy_path = Path(__file__).with_name('native-cold-policy.json')
        cold = json.loads(policy_path.read_text())
        result['cold_flash'] = {
            'version': cold['version'], 'functions': sorted(cold['functions']),
            'resident': cold['resident'], 'baseline_bytes': cold['baseline_bytes'],
            'resident_limit': cold['resident_limit'],
            'sources': {path: sha(root / path) for path in sorted(set(cold['functions'].values()))},
            'policy_sha256': sha(policy_path),
        }
        result['allowed_functions'] = sorted(set(result['allowed_functions']) | set(cold['functions']))
    if littlefs is not None:
        result['allowed_functions'] = sorted(set(result['allowed_functions']) | {'sdmmc_probe.ownedRead'})
        result['allowed_functions'] = sorted(set(result['allowed_functions']) | {
            'sdmmc.Controller(sdmmc_probe.Bus).' + name for name in
            ('prepare', 'identify', 'stopDma', 'releaseDma', 'readSector')})
        if 'pub const broker = true;' in (directory / 'native_options.zig').read_text():
            result['allowed_functions'] = sorted(set(result['allowed_functions']) | {'sdmmc_probe.qualifyLifetimes', 'main.runIoLifetimes'})
        root = Path(__file__).resolve().parents[1]
        result['io_lifetimes'] = {'version': 1, 'qualification': 'pub const broker = true;' in (directory / 'native_options.zig').read_text(), 'sources': {
            name: sha(root / name) for name in (
                'src/fs/io_leases.zig', 'src/fs/io_stop.zig', 'src/fs/sdmmc_owner.zig',
                'src/soc/esp32p4/sdmmc.zig', 'src/platform/native/sdmmc_probe.zig',
                'src/platform/native/main.zig', 'src/diagnostics/record.zig',
                'include/nihos_storage_io.h')}}
        result['io_lifetimes']['removal_test'] = 'pub const sd_removal = true;' in (directory / 'native_options.zig').read_text()
        result['io_lifetimes']['capture_handshake'] = 'pub const cold_capture = true;' in (directory / 'native_options.zig').read_text()
        if result['io_lifetimes']['capture_handshake']:
            result['io_lifetimes']['capture_format'] = 2
            result['allowed_functions'] = sorted(set(result['allowed_functions']) | {'main.captureBoot'})
            result['io_lifetimes']['capture_sources'] = {name: sha(root / name) for name in (
                'probes/sdmmc/pads.c', 'src/platform/native/esp32p4.ld', 'src/soc/esp32p4/reset_capture.zig')}
        if result['io_lifetimes']['removal_test']:
            result['allowed_functions'] = sorted(set(result['allowed_functions']) | {
                'sdmmc_probe.qualifyRemoval', 'sdmmc_probe.freshCardSession', 'sdmmc_probe.operatorMarker'})
        result['littlefs'] = {'revision': '6cb4e86540eca0d9ba62500a298385c9d863c8be',
                             'read_only': True, 'no_malloc': True, 'api_version': 1, 'workspace_bytes': 8192,
                             'shared_span': 'SQLite mapped code and rodata',
                             'sources': {name: sha(littlefs / name) for name in ('lfs.c', 'lfs.h', 'lfs_util.c', 'lfs_util.h', 'LICENSE.md')},
                             'adapter_sha256': sha(Path(__file__).resolve().parents[1] / 'probes/storage/littlefs_ro.c'),
                             'api_source_sha256': sha(Path(__file__).resolve().parents[1] / 'src/services/storage_littlefs.c'),
                             'api_header_sha256': sha(Path(__file__).resolve().parents[1] / 'include/nihos_storage.h'),
                             'api_internal_sha256': sha(Path(__file__).resolve().parents[1] / 'src/services/storage_internal.h')}
    if littlefs is not None and 'pub const storage_service = true;' in (directory / 'native_options.zig').read_text():
        root = Path(__file__).resolve().parents[1]
        result['littlefs']['service'] = {'version': 3, 'ipc_start': '0x48004000', 'ipc_bytes': 8192,
                                        'clock_group': 1, 'clock_channel': 0,
                                        'runtime_sha256': sha(root / 'src/platform/native/storage_runtime.zig'),
                                        'protocol_sha256': sha(root / 'src/kernel/storage_rpc.zig')}
    (directory / 'sqlite-manifest.json').write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main(*map(Path, sys.argv[1:]))
