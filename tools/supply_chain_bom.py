#!/usr/bin/env python3
"""Generate explicitly incomplete CycloneDX source inventories for a native image."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import tomllib

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


def generate(root, image_dir, output):
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
    flash = image.read_bytes()
    app_bytes = app.read_bytes()
    if flash[0x10000:0x10000 + len(app_bytes)] != app_bytes:
        raise ValueError('flash image does not contain the audited application at 0x10000')
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
    # The native image audit already verifies the manifest identities embedded in
    # the ELF. Recheck those identities before extracting the two known inputs.
    audited = []
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
        sqlite = next(e for e in sources if e['name'].startswith('SQLite amalgamation'))
        audited.append({'type': 'library', 'name': 'SQLite', 'version': sqlite['revision'],
            'hashes': [{'alg': 'SHA-256', 'content': sqlite_files[0][1]}],
            'properties': [prop('evidence', 'sqld manifest identity checked by image audit'),
                           prop('hash-scope', 'sqlite3.c source, not the whole package')]})
    base = {'bomFormat': 'CycloneDX', 'specVersion': '1.6', 'version': 1, 'metadata': metadata}
    output.mkdir(parents=True, exist_ok=True)
    for name, entries in [('source-sbom.cdx.json', components), ('source-cbom.cdx.json', crypto), ('audited-inputs.cdx.json', audited)]:
        (output / name).write_text(json.dumps({**base, 'components': entries}, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image_dir', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    generate(ROOT, args.image_dir, args.output)


if __name__ == '__main__':
    main()
