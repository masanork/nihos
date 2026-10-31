"""Build identity for the ordinary read-only filesystem. Not attestation.

The linked identity binds the allowlist, exact inputs and objects to this ELF;
editing a sidecar cannot turn an older image into a new service candidate.
"""
import hashlib
import json
import os
from pathlib import Path
import runpy
import struct

ROOT = Path(__file__).resolve().parents[1]
MAGIC = b'NIHOS_FS_NORMAL1'
PROFILE = (1, 65536, 32768, 0x40020000, 0x40060000, 4096, 0, 1)
SECTIONS = {'.flash.fspad', '.flash.fstext', '.flash.fsrodata'}
REQUIRED = {'nih_normal_fs_task', 'nih_normal_fs_begin', 'nih_normal_fs_submit',
            'nih_normal_fs_poll', 'nih_normal_fs_result', 'nih_storage_read',
            'nih_shared_sdmmc_acquire', 'nih_shared_sdmmc_release',
            'nih_fatfs_card_mount_volume', 'nih_fatfs_card_destroy', 'nih_fatfs_backend_read'}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def digest(manifest):
    return hashlib.sha256(json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode()).digest()


def create(directory, source, objects):
    functions = runpy.run_path(str(ROOT / 'tools/native-sqlite-manifest.py'))['functions']
    inputs = sorted(p for p in (ROOT / 'src').rglob('*') if p.suffix in ('.zig', '.c', '.h', '.S', '.ld'))
    inputs += sorted((ROOT / 'include').glob('*.h'))
    inputs += [ROOT / name for name in ('tools/normal_fs_build.py', 'tools/normal_fs_manifest.py',
        'tools/check-native-image.py', 'tools/check-normal-native.py', 'tools/build-native-elf.sh', 'tools/build-native.sh',
        'tools/bootstrap-fatfs.py', 'probes/fatfs-disk/safety.c', 'probes/fatfs-disk/safety.h',
        'probes/fatfs-disk/ffconf.h', 'probes/sdmmc/pads.c', 'probes/c6-sdio/pads.c', 'provenance.toml')]
    manifest = {'schema': 1, 'kind': 'normal-readonly-fs', 'profile': list(PROFILE),
        'sqld_enabled': os.environ.get('NIHOS_NATIVE_SQLD') == '1',
        'sqld_profile_sha256': sha(directory / 'sqld_profile.zig'),
        'sources': {str(p.relative_to(ROOT)): sha(p) for p in inputs},
        'upstream': {p.name: sha(p) for p in sorted(source.iterdir()) if p.is_file()},
        'objects': {p.name: {'sha256': sha(p), 'functions': functions(p)} for p in objects}}
    manifest['allowed_functions'] = sorted(set().union(*(set(v['functions']) for v in manifest['objects'].values())))
    identity = MAGIC + digest(manifest) + struct.pack('<8I', *PROFILE)
    (directory / 'normal-fs-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    path = directory / 'normal-fs-identity.c'
    path.write_text('__attribute__((used,section(".normal_fs.identity")))\n'
                    'const unsigned char nih_normal_fs_identity[] = {' + ','.join(map(str, identity)) + '};\n')
    return path


def validate(manifest):
    if manifest.get('schema') != 1 or manifest.get('kind') != 'normal-readonly-fs' or manifest.get('profile') != list(PROFILE):
        raise ValueError('invalid ordinary FS profile')
    units = {'runtime', 'guard', 'unicode', 'backend', 'disk', 'volume', 'card', 'native_disk', 'strings'}
    if set(manifest.get('objects', {})) != {'normal_fs_' + name + '.o' for name in units}:
        raise ValueError('unexpected ordinary FS object set')
    allowed = sorted(set().union(*(set(v['functions']) for v in manifest['objects'].values())))
    if manifest.get('allowed_functions') != allowed or not REQUIRED.issubset(allowed):
        raise ValueError('invalid ordinary FS allowlist')
    return MAGIC + digest(manifest) + struct.pack('<8I', *PROFILE)


def verify_files(directory, manifest):
    validate(manifest)
    if sha(directory / 'sqld_profile.zig') != manifest.get('sqld_profile_sha256'): raise ValueError('SD block grant profile differs')
    if not all(sha(ROOT / name) == value for name, value in manifest['sources'].items()):
        raise ValueError('ordinary FS source differs from candidate')
    if not all(sha(directory / name) == value['sha256'] for name, value in manifest['objects'].items()):
        raise ValueError('ordinary FS object differs from candidate')
