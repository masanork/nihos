import copy
import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import native_build_tool_evidence as evidence
import verify_native_provenance as verifier


class ToolEvidenceTest(unittest.TestCase):
    def test_observe_detects_changed_compiler_and_dirty_or_wrong_idf(self):
        with tempfile.TemporaryDirectory() as d:
            zig = Path(d) / 'zig'
            zig.write_bytes(b'compiler')
            def command(args, **kwargs):
                if args[-1] == 'version':
                    return '0.17.0\n'
                if args[-1] == 'HEAD':
                    return evidence.IDF_COMMIT + '\n'
                return ''
            with patch.object(evidence.subprocess, 'check_output', side_effect=command):
                first = evidence.observe(zig, Path(d))
                self.assertEqual(first['zig_sha256'], hashlib.sha256(b'compiler').hexdigest())
                zig.write_bytes(b'changed')
                self.assertNotEqual(first, evidence.observe(zig, Path(d)))
            with patch.object(evidence.subprocess, 'check_output', side_effect=['0.17.0\n', evidence.IDF_COMMIT + '\n', ' M modified\n']):
                with self.assertRaises(ValueError):
                    evidence.observe(zig, Path(d))
            with patch.object(evidence.subprocess, 'check_output', side_effect=['0.17.0\n', 'a' * 40 + '\n', '']):
                with self.assertRaises(ValueError):
                    evidence.observe(zig, Path(d))

    def test_signed_inventories_must_agree_and_old_ones_are_rejected_when_required(self):
        import json
        receipt = {'schema': 1, 'zig_version': '0.17.0', 'zig_sha256': 'a' * 64,
                   'idf_commit': evidence.IDF_COMMIT, 'idf_tracked_clean': True}
        prop = {'name': 'nihos:build-tool-evidence', 'value': json.dumps(receipt)}
        documents = [{'metadata': {'properties': [copy.deepcopy(prop)]}} for _ in range(3)]
        self.assertEqual(verifier.check_build_tool_evidence(documents, 'a' * 64), receipt)
        with self.assertRaises(ValueError):
            verifier.check_build_tool_evidence(documents, 'b' * 64)
        documents[1]['metadata']['properties'][0]['value'] = json.dumps({**receipt, 'zig_sha256': 'b' * 64})
        with self.assertRaises(ValueError):
            verifier.check_build_tool_evidence(documents)
        documents[1]['metadata']['properties'] = []
        with self.assertRaises(ValueError):
            verifier.check_build_tool_evidence(documents)
        documents[1]['metadata']['properties'] = [prop, prop]
        with self.assertRaises(ValueError):
            verifier.check_build_tool_evidence(documents)


if __name__ == '__main__':
    unittest.main()
