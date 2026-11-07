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
            (root / 'bom' / verify.SUBJECTS[1]).write_text('{}')
            with self.assertRaises(ValueError):
                verify.verify(root, SHA, REF)


if __name__ == '__main__':
    unittest.main()
