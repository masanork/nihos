#!/usr/bin/env python3
"""Verify an experimental native artifact set against a narrow GitHub policy.

Only statements returned by a successful gh attestation verify are passed to
check_statement. This tool does not implement signature verification itself.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

REPO = 'masanork/nihos'
WORKFLOW = '.github/workflows/native.yml'
SIGNER = '.github/workflows/native-provenance.yml'
BUILD_TYPE = 'https://actions.github.io/buildtypes/workflow/v1'
PREDICATE = 'https://slsa.dev/provenance/v1'
SUBJECTS = ('nihos-native-flash.bin', 'audited-inputs.cdx.json',
            'source-cbom.cdx.json', 'source-sbom.cdx.json')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_statement(statement, hashes, source_sha, source_ref):
    """Check one cryptographically verified statement; raise on policy mismatch."""
    if statement.get('_type') != 'https://in-toto.io/Statement/v1' or statement.get('predicateType') != PREDICATE:
        raise ValueError('unexpected statement or predicate type')
    subjects = statement.get('subject')
    if not isinstance(subjects, list) or len(subjects) != len(SUBJECTS):
        raise ValueError('unexpected subject set')
    found = {}
    for subject in subjects:
        if not isinstance(subject, dict) or set(subject) != {'name', 'digest'}:
            raise ValueError('invalid subject')
        name, value = subject['name'], subject['digest']
        if name not in SUBJECTS or name in found or not isinstance(value, dict) or value != {'sha256': hashes[name]}:
            raise ValueError('subject name or digest differs')
        found[name] = value
    if set(found) != set(SUBJECTS):
        raise ValueError('missing subject')
    predicate = statement.get('predicate', {})
    definition = predicate.get('buildDefinition', {})
    if definition.get('buildType') != BUILD_TYPE:
        raise ValueError('unexpected build type')
    expected = {'workflow': {'path': WORKFLOW, 'ref': source_ref,
                             'repository': 'https://github.com/' + REPO}}
    if definition.get('externalParameters') != expected:
        raise ValueError('unexpected external parameters')
    internal = definition.get('internalParameters', {}).get('github', {})
    if internal.get('event_name') != 'workflow_dispatch' or internal.get('runner_environment') != 'github-hosted':
        raise ValueError('unexpected event or runner')
    builder = predicate.get('runDetails', {}).get('builder', {}).get('id')
    if builder != f'https://github.com/{REPO}/{SIGNER}@{source_ref}':
        raise ValueError('unexpected builder identity')
    deps = definition.get('resolvedDependencies')
    source = {'uri': f'git+https://github.com/{REPO}@{source_ref}',
              'digest': {'gitCommit': source_sha}}
    if not isinstance(deps, list) or source not in deps:
        raise ValueError('missing source dependency')


def check_image_layout(flash, bom, required=False):
    """Validate signed binary inventory against the complete flash byte layout."""
    expected = [('bootloader.bin', 0x2000, 0x8000),
                ('partition-table.bin', 0x8000, 0x10000),
                ('nihos-native.bin', 0x10000, None)]
    components = bom.get('components', [])
    if not isinstance(components, list):
        raise ValueError('invalid audited inventory components')
    binaries = [c for c in components if isinstance(c, dict) and c.get('name') in {x[0] for x in expected}]
    for component in binaries:
        if not isinstance(component.get('properties', []), list):
            raise ValueError('invalid binary properties')
    has_sizes = any(any(p.get('name') == 'nihos:flash-size-bytes' for p in c.get('properties', []) if isinstance(p, dict)) for c in binaries)
    if not has_sizes and not required:
        return False  # Older signed inventories did not contain lengths.
    cursor = 0
    for name, offset, limit in expected:
        matches = [c for c in binaries if c.get('name') == name]
        if len(matches) != 1 or matches[0].get('type') != 'file':
            raise ValueError(f'missing or duplicate image binary {name}')
        component = matches[0]
        properties = component.get('properties', [])
        if not isinstance(properties, list):
            raise ValueError('invalid binary properties')
        def one(key):
            values = [p.get('value') for p in properties if isinstance(p, dict) and p.get('name') == key]
            if len(values) != 1 or not isinstance(values[0], str):
                raise ValueError(f'missing or duplicate {key}')
            return values[0]
        size_text = one('nihos:flash-size-bytes')
        if one('nihos:flash-offset') != hex(offset) or not re.fullmatch(r'[1-9][0-9]*', size_text):
            raise ValueError(f'invalid image layout for {name}')
        size = int(size_text)
        end = offset + size
        if end > len(flash) or (limit is not None and end > limit):
            raise ValueError(f'image binary {name} exceeds its flash region')
        if flash[cursor:offset] != b'\xff' * (offset - cursor):
            raise ValueError(f'unexpected padding before {name}')
        expected_hash = hashlib.sha256(flash[offset:end]).hexdigest()
        if component.get('hashes') != [{'alg': 'SHA-256', 'content': expected_hash}]:
            raise ValueError(f'image binary digest differs for {name}')
        cursor = end
    if cursor != len(flash):
        raise ValueError('unexpected data after the application')
    return True


def check_audit_evidence(directory, inventories):
    """Check the retained audit and ELF against the verified inventory set."""
    elf_hash = digest(directory / 'nihos-native.elf')
    audit_path = directory / 'image-audit.json'
    audit_hash = digest(audit_path)
    for bom in inventories:
        properties = bom.get('metadata', {}).get('properties', [])
        if not isinstance(properties, list):
            raise ValueError('invalid inventory metadata properties')
        for name, expected in (('nihos:elf-sha256', elf_hash), ('nihos:image-audit-sha256', audit_hash)):
            values = [p.get('value') for p in properties if isinstance(p, dict) and p.get('name') == name]
            if values != [expected]:
                raise ValueError(f'inventory {name} differs from retained evidence')
    audit = json.loads(audit_path.read_text())
    if audit.get('elf_sha256') != elf_hash or audit.get('memory', {}).get('profile') != 'device':
        raise ValueError('image audit ELF digest or device profile differs')
    # The image layout checker already verified the application component's
    # offset, size and hash against the flash image. Recheck the audit's app hash.
    app = [c for c in inventories[0].get('components', []) if isinstance(c, dict) and c.get('name') == 'nihos-native.bin']
    if len(app) != 1 or app[0].get('hashes') != [{'alg': 'SHA-256', 'content': audit.get('image_sha256')}]:
        raise ValueError('image audit application digest differs from flash inventory')


def verify(directory, source_sha, source_ref, bundle=None, require_image_layout=False, require_audit_evidence=False):
    if not re.fullmatch(r'[0-9a-f]{40}', source_sha):
        raise ValueError('source SHA must be 40 lowercase hexadecimal characters')
    if not re.fullmatch(r'refs/heads/[A-Za-z0-9][A-Za-z0-9._/-]*', source_ref):
        raise ValueError('expected a full branch ref')
    files = {SUBJECTS[0]: directory / SUBJECTS[0]}
    files.update({name: directory / 'bom' / name for name in SUBJECTS[1:]})
    hashes = {name: digest(path) for name, path in files.items()}
    inventories = []
    for name in SUBJECTS[1:]:
        bom = json.loads(files[name].read_text())
        inventories.append(bom)
        component = bom.get('metadata', {}).get('component', {})
        if {'alg': 'SHA-256', 'content': hashes[SUBJECTS[0]]} not in component.get('hashes', []):
            raise ValueError('inventory image digest differs')
    flash = files[SUBJECTS[0]].read_bytes()
    check_image_layout(flash, inventories[0], require_image_layout or require_audit_evidence)
    command = ['gh', 'attestation', 'verify', str(files[SUBJECTS[0]]), '--repo', REPO,
               '--signer-workflow', f'{REPO}/{SIGNER}', '--source-ref', source_ref,
               '--source-digest', source_sha, '--signer-digest', source_sha,
               '--deny-self-hosted-runners', '--format', 'json']
    if bundle is not None:
        command.extend(['--bundle', str(bundle)])
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    verified = json.loads(result.stdout)
    if not isinstance(verified, list) or not verified:
        raise ValueError('no verified attestations')
    for item in verified:
        try:
            check_statement(item['verificationResult']['statement'], hashes, source_sha, source_ref)
        except (KeyError, TypeError, ValueError):
            continue
        if require_audit_evidence:
            check_audit_evidence(directory, inventories)
        return hashes
    raise ValueError('no verified statement satisfies native provenance policy')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path, help='directory containing image and bom/')
    parser.add_argument('--source-sha', required=True, help='independently trusted source and signer commit')
    parser.add_argument('--source-ref', default='refs/heads/main', help='independently trusted branch ref')
    parser.add_argument('--bundle', type=Path, help='optional downloaded Sigstore bundle')
    parser.add_argument('--require-image-layout', action='store_true',
                        help='require and verify binary offsets, lengths and digests')
    parser.add_argument('--require-audit-evidence', action='store_true',
                        help='require and verify retained image audit and ELF (also requires image layout)')
    args = parser.parse_args()
    try:
        hashes = verify(args.directory, args.source_sha, args.source_ref, args.bundle, args.require_image_layout, args.require_audit_evidence)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as exc:
        print(f'native provenance verification failed: {exc}', file=sys.stderr)
        return 1
    print(json.dumps({'policy': 'experimental-native-main-v1', 'source_sha': args.source_sha,
                      'source_ref': args.source_ref, 'image_layout_required': args.require_image_layout or args.require_audit_evidence,
                      'audit_evidence_verified': args.require_audit_evidence, 'subjects': hashes}, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
