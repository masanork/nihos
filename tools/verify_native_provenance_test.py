import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import verify_native_provenance as verify

SHA = 'a' * 40
REF = 'refs/heads/main'


def statement(hashes):
    return {'_type': 'https://in-toto.io/Statement/v1', 'predicateType': verify.PREDICATE,
            'subject': [{'name': n, 'digest': {'sha256': hashes[n]}} for n in verify.SUBJECTS],
            'predicate': {'buildDefinition': {'buildType': verify.BUILD_TYPE,
                'externalParameters': {'workflow': {'path': verify.WORKFLOW, 'ref': REF,
                                      'repository': 'https://github.com/' + verify.REPO}},
                'internalParameters': {'github': {'event_name': 'workflow_dispatch', 'runner_environment': 'github-hosted'}},
                'resolvedDependencies': [{'uri': f'git+https://github.com/{verify.REPO}@{REF}',
                                          'digest': {'gitCommit': SHA}}]},
                'runDetails': {'builder': {'id': f'https://github.com/{verify.REPO}/{verify.SIGNER}@{REF}'}}}}


class PolicyTest(unittest.TestCase):
    def test_rejects_changed_claims_and_unknown_parameters(self):
        hashes = {name: hashlib.sha256(name.encode()).hexdigest() for name in verify.SUBJECTS}
        valid = statement(hashes)
        verify.check_statement(valid, hashes, SHA, REF)
        mutations = []
        x = copy.deepcopy(valid); x['predicate']['buildDefinition']['externalParameters']['extra'] = 'unexpected'; mutations.append(x)
        x = copy.deepcopy(valid); x['predicate']['buildDefinition']['buildType'] = 'other'; mutations.append(x)
        x = copy.deepcopy(valid); x['predicate']['runDetails']['builder']['id'] += '-wrong'; mutations.append(x)
        x = copy.deepcopy(valid); x['predicate']['buildDefinition']['internalParameters']['github']['event_name'] = 'push'; mutations.append(x)
        x = copy.deepcopy(valid); x['predicate']['buildDefinition']['resolvedDependencies'][0]['digest']['gitCommit'] = 'b' * 40; mutations.append(x)
        x = copy.deepcopy(valid); x['subject'][1]['digest']['sha256'] = '0' * 64; mutations.append(x)
        x = copy.deepcopy(valid); x['subject'][1] = copy.deepcopy(x['subject'][0]); mutations.append(x)
        x = copy.deepcopy(valid); x['subject'].append(copy.deepcopy(x['subject'][0])); mutations.append(x)
        for value in mutations:
            with self.subTest(value=value), self.assertRaises(ValueError):
                verify.check_statement(value, hashes, SHA, REF)

    def test_binary_layout_checks_and_legacy_compatibility(self):
        flash = bytearray(b'\xff' * 0x10000 + b'app')
        flash[0x2000:0x2004] = b'boot'
        flash[0x8000:0x8009] = b'partition'
        components = []
        for name, offset, payload in [('bootloader.bin', 0x2000, b'boot'),
                                      ('partition-table.bin', 0x8000, b'partition'),
                                      ('nihos-native.bin', 0x10000, b'app')]:
            components.append({'name': name, 'type': 'file',
                'hashes': [{'alg': 'SHA-256', 'content': hashlib.sha256(payload).hexdigest()}],
                'properties': [{'name': 'nihos:flash-offset', 'value': hex(offset)},
                               {'name': 'nihos:flash-size-bytes', 'value': str(len(payload))}]})
        bom = {'components': components}
        self.assertTrue(verify.check_image_layout(flash, bom, required=True))
        for offset in (0, 0x2000, 0x8000, 0x10000):
            altered = bytearray(flash); altered[offset] ^= 1
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                verify.check_image_layout(altered, bom, required=True)
        for changed in (flash[:-1], flash + b'\xff'):
            with self.assertRaises(ValueError):
                verify.check_image_layout(changed, bom, required=True)
        variants = []
        x = copy.deepcopy(bom); x['components'].append(copy.deepcopy(x['components'][0])); variants.append(x)
        x = copy.deepcopy(bom); x['components'][0]['properties'][1]['value'] = '999999'; variants.append(x)
        x = copy.deepcopy(bom); x['components'][1]['properties'][0]['value'] = '0x9000'; variants.append(x)
        x = copy.deepcopy(bom); x['components'][2]['hashes'][0]['content'] = '0' * 64; variants.append(x)
        x = copy.deepcopy(bom); x['components'][2]['properties'].pop(); variants.append(x)
        for x in variants:
            with self.assertRaises(ValueError):
                verify.check_image_layout(flash, x, required=True)
        old = copy.deepcopy(bom)
        for component in old['components']:
            component['properties'].pop()
        self.assertFalse(verify.check_image_layout(flash, old))
        with self.assertRaises(ValueError):
            verify.check_image_layout(flash, old, required=True)

    def test_retained_audit_and_elf_must_match_all_signed_inventories(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            elf = root / 'nihos-native.elf'; elf.write_bytes(b'elf')
            audit_file = root / 'image-audit.json'
            app_hash = hashlib.sha256(b'app').hexdigest()
            audit = {'elf_sha256': verify.digest(elf), 'image_sha256': app_hash,
                     'memory': {'profile': 'device'}}
            audit_file.write_text(json.dumps(audit))
            properties = [{'name': 'nihos:elf-sha256', 'value': verify.digest(elf)},
                          {'name': 'nihos:image-audit-sha256', 'value': verify.digest(audit_file)}]
            boms = [{'metadata': {'properties': copy.deepcopy(properties)}} for _ in range(3)]
            boms[0]['components'] = [{'name': 'nihos-native.bin', 'hashes': [{'alg': 'SHA-256', 'content': app_hash}]}]
            verify.check_audit_evidence(root, boms)
            audit_file.write_text(json.dumps({**audit, 'image_sha256': '0' * 64}))
            with self.assertRaises(ValueError):
                verify.check_audit_evidence(root, boms)
            for bom in boms:
                bom['metadata']['properties'][1]['value'] = verify.digest(audit_file)
            with self.assertRaises(ValueError):
                verify.check_audit_evidence(root, boms)
            audit_file.write_text(json.dumps(audit))
            for bom in boms:
                bom['metadata']['properties'][1]['value'] = verify.digest(audit_file)
            elf.write_bytes(b'tampered')
            with self.assertRaises(ValueError):
                verify.check_audit_evidence(root, boms)
            elf.write_bytes(b'elf')
            boms[1]['metadata']['properties'].append(copy.deepcopy(properties[0]))
            with self.assertRaises(ValueError):
                verify.check_audit_evidence(root, boms)
            audit_file.unlink()
            with self.assertRaises(OSError):
                verify.check_audit_evidence(root, boms)

    def test_requires_matching_inventory_and_invokes_gh_with_pins(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); (root / 'bom').mkdir()
            (root / verify.SUBJECTS[0]).write_bytes(b'image')
            image_hash = hashlib.sha256(b'image').hexdigest()
            for name in verify.SUBJECTS[1:]:
                (root / 'bom' / name).write_text(json.dumps({'metadata': {'component': {'hashes': [{'alg': 'SHA-256', 'content': image_hash}]}}}))
            hashes = {verify.SUBJECTS[0]: image_hash}
            hashes.update({name: verify.digest(root / 'bom' / name) for name in verify.SUBJECTS[1:]})
            result = type('Result', (), {'stdout': json.dumps([{'verificationResult': {'statement': statement(hashes)}}])})()
            with patch.object(verify.subprocess, 'run', return_value=result) as run:
                self.assertEqual(verify.verify(root, SHA, REF), hashes)
                args = run.call_args.args[0]
                self.assertIn('--signer-digest', args)
                self.assertIn('--source-ref', args)
                self.assertIn('--deny-self-hosted-runners', args)
                self.assertTrue(run.call_args.kwargs['check'])
            with patch.object(verify.subprocess, 'run', return_value=result), \
                    patch.object(verify, 'check_image_layout') as layout, \
                    patch.object(verify, 'check_audit_evidence') as audit_check:
                self.assertEqual(verify.verify(root, SHA, REF, require_audit_evidence=True), hashes)
                self.assertTrue(layout.call_args.args[2])
                audit_check.assert_called_once()
            (root / 'bom' / verify.SUBJECTS[1]).write_text('{}')
            with self.assertRaises(ValueError):
                verify.verify(root, SHA, REF)


if __name__ == '__main__':
    unittest.main()
