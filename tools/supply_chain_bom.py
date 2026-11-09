#!/usr/bin/env python3
"""Generate explicitly incomplete CycloneDX source inventories for a native image."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import tomllib

import native_build_tool_evidence

ROOT = Path(__file__).resolve().parent.parent
# Patterns identify source candidates, not linked or reachable implementations.
PATTERNS = {
    'SHA-256': (r'\b(?:Sha256|SHA256|sha256)\b', 'hash'),
    'HMAC-SHA-256': (r'\bHmacSha256\b', 'mac'),
    'BLAKE2s-256': (r'\bBlake2s256\b', 'hash'),
    'X25519': (r'\bX25519\b', 'key-agree'),
    'Ed25519': (r'\bEd25519\b', 'signature'),
    # The card verifier implements RSA with Zig's generic finite-field API.
    # A Modulus match is a candidate only, not proof of RSA or image membership.
    'RSA-2048': (r'(?i:\bRSA[-_ ]?2048\b)|\bRsa2048\b|std\.crypto\.ff\.Modulus\s*\(\s*2048\s*\)', 'signature'),
    'AES-128': (r'\bAes128\b', 'block-cipher'),
    'ChaCha20-Poly1305': (r'\bChaCha20Poly1305\b', 'ae'),
    'ML-KEM': (r'\b(?:MlKem|MLKEM|mlkem)\w*\b', 'kem'),
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prop(name, value):
    return {'name': 'nihos:' + name, 'value': str(value)}


def generate(root, image_dir, output, tool_evidence=None):
    elf = image_dir / 'nihos-native.elf'
    image = image_dir / 'nihos-native-flash.bin'
    audit = json.loads((image_dir / 'image-audit.json').read_text())
    if audit.get('elf_sha256') != digest(elf):
        raise ValueError('image audit ELF digest does not match the supplied ELF')
    if audit.get('memory', {}).get('profile') != 'device':
        raise ValueError('image audit is not a device profile')
    app = image_dir / 'nihos-native.bin'
    if audit.get('image_sha256') != digest(app):
        raise ValueError('image audit application digest does not match the supplied binary')
    loader_elf = image_dir / 'loader/bootloader/bootloader.elf'
    loader_config = image_dir / 'loader/config/sdkconfig.h'
    if audit.get('loader', {}).get('elf_sha256') != digest(loader_elf):
        raise ValueError('image audit loader ELF digest does not match')
    config_hash = hashlib.sha256(loader_config.read_text().encode()).hexdigest()
    if audit.get('loader_config', {}).get('config_sha256') != config_hash:
        raise ValueError('image audit loader configuration digest does not match')
    flash = image.read_bytes()
    parts = [
        ('bootloader.bin', image_dir / 'loader/bootloader/bootloader.bin', 0x2000, 0x8000),
        ('partition-table.bin', image_dir / 'loader/partition_table/partition-table.bin', 0x8000, 0x10000),
        ('nihos-native.bin', app, 0x10000, None),
    ]
    binary_components = []
    cursor = 0
    for name, path, offset, limit in parts:
        data = path.read_bytes()
        if not data or (limit is not None and offset + len(data) > limit):
            raise ValueError(f'{name} is empty or exceeds its flash region')
        if flash[cursor:offset] != b'\xff' * (offset - cursor):
            raise ValueError(f'unexpected flash padding before {name}')
        if flash[offset:offset + len(data)] != data:
            raise ValueError(f'flash image does not contain {name} at {offset:#x}')
        binary_components.append({'type': 'file', 'name': name,
            'hashes': [{'alg': 'SHA-256', 'content': hashlib.sha256(data).hexdigest()}],
            'properties': [prop('evidence', 'byte-identical flash slice'),
                           prop('flash-offset', hex(offset)),
                           prop('flash-size-bytes', len(data))]})
        cursor = offset + len(data)
    if len(flash) != cursor:
        raise ValueError('unexpected data after the application in flash image')
    image_hash = digest(image)
    subject = {'type': 'firmware', 'name': image.name,
               'hashes': [{'alg': 'SHA-256', 'content': image_hash}]}
    zig_files = sorted((root / 'src').rglob('*.zig'))
    source_hash = hashlib.sha256()
    for path in zig_files:
        source_hash.update(str(path.relative_to(root)).encode() + b'\0')
        source_hash.update(bytes.fromhex(digest(path)))
    metadata = {'component': subject, 'properties': [
        prop('inventory-scope', 'source candidates; image membership and completeness unverified'),
        prop('elf-sha256', digest(elf)),
        prop('image-audit-sha256', digest(image_dir / 'image-audit.json')),
        prop('provenance-toml-sha256', digest(root / 'provenance.toml')),
        prop('zig-source-set-sha256', source_hash.hexdigest()),
    ]}
    if tool_evidence is not None:
        evidence = native_build_tool_evidence.validate(tool_evidence)
        metadata['properties'].append(prop('build-tool-evidence', json.dumps(evidence, sort_keys=True, separators=(',', ':'))))
    components = []
    sources = tomllib.loads((root / 'provenance.toml').read_text())['source']
    for i, entry in enumerate(sources):
        components.append({'type': 'library', 'bom-ref': f'source-{i}',
            'name': entry['name'], 'version': entry.get('revision', 'unknown'),
            'description': entry.get('use', ''), 'properties': [
                prop('source-status', entry['status']), prop('license-text', entry.get('license', 'unknown')),
                prop('source-url', entry.get('url', 'unknown')),
                prop('image-membership', 'unverified')]})
    found = {name: [] for name in PATTERNS}
    for path in zig_files:
        for n, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
            # Comments and tests can still match; the status records this limitation.
            for name, (pattern, _) in PATTERNS.items():
                if re.search(pattern, line):
                    found[name].append(f'{path.relative_to(root)}:{n}')
    crypto = []
    for name, locations in found.items():
        if locations:
            crypto.append({'type': 'cryptographic-asset', 'name': name,
                'cryptoProperties': {'assetType': 'algorithm',
                    'algorithmProperties': {'primitive': PATTERNS[name][1]}},
                'properties': [prop('evidence', 'source text match; includes possible comments and tests'),
                    prop('image-membership', 'unverified')] +
                    [prop('source-location', location) for location in locations]})
    photo = audit.get('photo_codec') or {}
    rsa_evidence = photo.get('card_rsa_link_evidence')
    if rsa_evidence:
        manifest = json.loads((image_dir / 'photo-manifest.json').read_text())
        manifest_hash = hashlib.sha256(json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        if manifest_hash != photo.get('manifest_sha256'):
            raise ValueError('photo manifest differs from image audit')
        source_path = 'src/card/license_crypto.zig'
        source_digest = digest(root / source_path)
        config = manifest.get('license_crypto', {})
        if (manifest.get('sources', {}).get(source_path) != source_digest or
                not manifest.get('automatic_cards', {}).get('read_enabled') or
                config.get('profile') != 'npa-raw-sha256-v1_5' or config.get('bits') != 2048 or
                rsa_evidence.get('function') != 'nih_card_crypto' or
                rsa_evidence.get('profile') != config.get('profile') or rsa_evidence.get('bits') != 2048 or
                'nih_card_crypto' not in config.get('allowed_functions', [])):
            raise ValueError('card RSA evidence differs from source or manifest')
        rsa = next((c for c in crypto if c['name'] == 'RSA-2048'), None)
        if rsa is None:
            raise ValueError('card RSA evidence has no source candidate')
        rsa['properties'] = [p for p in rsa['properties'] if p['name'] != 'nihos:image-membership']
        rsa['properties'] += [prop('image-membership', 'linked entry point evidence; runtime execution unverified'),
            prop('linked-function', rsa_evidence['function']),
            prop('linked-function-address', rsa_evidence['function_address']),
            prop('source-sha256', source_digest),
            prop('audited-profile', config['profile']),
            prop('usage-context', 'card signature verification; trust and runtime operation unverified')]
    # The native image audit already verifies the manifest identities embedded in
    # the ELF. Recheck those identities before extracting the two known inputs.
    audited = binary_components
    if audit.get('normal_fs'):
        manifest = json.loads((image_dir / 'normal-fs-manifest.json').read_text())
        manifest_hash = hashlib.sha256(json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        if manifest_hash != audit['normal_fs'].get('manifest_sha256'):
            raise ValueError('normal FS manifest differs from image audit')
        fatfs = next(e for e in sources if e['name'] == 'FatFs')
        if manifest['upstream'].get('ff.c') != fatfs.get('patched_ff_c_sha256'):
            raise ValueError('FatFs source differs from provenance pin')
        audited.append({'type': 'library', 'name': 'FatFs', 'version': fatfs['revision'],
            'hashes': [{'alg': 'SHA-256', 'content': manifest['upstream']['ff.c']}],
            'properties': [prop('evidence', 'normal-fs manifest identity checked by image audit'),
                           prop('hash-scope', 'patched ff.c source, not the whole package')]})
    if audit.get('sqld'):
        manifest = json.loads((image_dir / 'sqld-manifest.json').read_text())
        identity = hashlib.sha256(json.dumps({k: v for k, v in manifest.items() if k != 'identity'}, sort_keys=True).encode()).hexdigest()
        if identity != manifest.get('identity') or identity != audit['sqld'].get('identity'):
            raise ValueError('sqld manifest differs from image audit')
        sqlite_files = [(k, v) for k, v in manifest['sources'].items() if k.endswith('/sqlite3.c')]
        if len(sqlite_files) != 1 or digest(root / sqlite_files[0][0]) != sqlite_files[0][1]:
            raise ValueError('SQLite source differs from sqld manifest')
        sqlite_source = (root / sqlite_files[0][0]).read_text(encoding='utf-8')
        evidence = audit['sqld'].get('sqlite_prng_link_evidence')
        markers = ('static void chacha_block(', 'SQLITE_API void sqlite3_randomness(',
                   'chacha20_init[]', 'chacha_block((u32*)wsdPrng.out, wsdPrng.s);')
        if evidence and all(marker in sqlite_source for marker in markers):
            crypto.append({'type': 'cryptographic-asset', 'name': 'ChaCha20',
                'cryptoProperties': {'assetType': 'algorithm',
                    'algorithmProperties': {'primitive': 'stream-cipher'}},
                'properties': [prop('evidence', 'SQLite source markers and linked function and initialization constant'),
                    prop('source-location', sqlite_files[0][0]),
                    prop('source-sha256', sqlite_files[0][1]),
                    prop('linked-function', evidence['function']),
                    prop('linked-function-address', evidence['function_address']),
                    prop('linked-constant', evidence['constant']),
                    prop('image-membership', 'linked symbol evidence; algorithm bytes and runtime use unverified'),
                    prop('usage-context', 'SQLite pseudo-random generator; not evidence of encryption or entropy quality')]})
        sqlite = next(e for e in sources if e['name'].startswith('SQLite amalgamation'))
        audited.append({'type': 'library', 'name': 'SQLite', 'version': sqlite['revision'],
            'hashes': [{'alg': 'SHA-256', 'content': sqlite_files[0][1]}],
            'properties': [prop('evidence', 'sqld manifest identity checked by image audit'),
                           prop('hash-scope', 'sqlite3.c source, not the whole package')]})
    base = {'bomFormat': 'CycloneDX', 'specVersion': '1.6', 'version': 1, 'metadata': metadata}
    output.mkdir(parents=True, exist_ok=True)
    for name, entries in [('source-sbom.cdx.json', components), ('source-cbom.cdx.json', crypto), ('audited-inputs.cdx.json', audited)]:
        document = {**base, 'components': entries}
        if name == 'audited-inputs.cdx.json':
            document['metadata'] = {**metadata, 'properties': [
                prop('inventory-scope', 'partial audited inputs and matched image binaries; completeness unverified'),
                *metadata['properties'][1:]]}
        (output / name).write_text(json.dumps(document, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image_dir', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--tool-evidence', type=Path, help='pre/post checked native build tool receipt')
    args = parser.parse_args()
    evidence = json.loads(args.tool_evidence.read_text()) if args.tool_evidence else None
    generate(ROOT, args.image_dir, args.output, evidence)


if __name__ == '__main__':
    main()
