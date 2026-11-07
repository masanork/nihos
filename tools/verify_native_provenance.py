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


def verify(directory, source_sha, source_ref, bundle=None):
    if not re.fullmatch(r'[0-9a-f]{40}', source_sha):
        raise ValueError('source SHA must be 40 lowercase hexadecimal characters')
    if not re.fullmatch(r'refs/heads/[A-Za-z0-9][A-Za-z0-9._/-]*', source_ref):
        raise ValueError('expected a full branch ref')
    files = {SUBJECTS[0]: directory / SUBJECTS[0]}
    files.update({name: directory / 'bom' / name for name in SUBJECTS[1:]})
    hashes = {name: digest(path) for name, path in files.items()}
    for name in SUBJECTS[1:]:
        bom = json.loads(files[name].read_text())
        component = bom.get('metadata', {}).get('component', {})
        if {'alg': 'SHA-256', 'content': hashes[SUBJECTS[0]]} not in component.get('hashes', []):
            raise ValueError('inventory image digest differs')
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
            return hashes
        except (KeyError, TypeError, ValueError):
            continue
    raise ValueError('no verified statement satisfies native provenance policy')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path, help='directory containing image and bom/')
    parser.add_argument('--source-sha', required=True, help='independently trusted source and signer commit')
    parser.add_argument('--source-ref', default='refs/heads/main', help='independently trusted branch ref')
    parser.add_argument('--bundle', type=Path, help='optional downloaded Sigstore bundle')
    args = parser.parse_args()
    try:
        hashes = verify(args.directory, args.source_sha, args.source_ref, args.bundle)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as exc:
        print(f'native provenance verification failed: {exc}', file=sys.stderr)
        return 1
    print(json.dumps({'policy': 'experimental-native-main-v1', 'source_sha': args.source_sha,
                      'source_ref': args.source_ref, 'subjects': hashes}, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
