import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import supply_chain_bom as bom


class BomTest(unittest.TestCase):
    def test_candidates_and_image_binding(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / 'src').mkdir()
            (root / 'src' / 'demo.zig').write_text('const X = std.crypto.dh.X25519;\nconst M = std.crypto.ff.Modulus(2048);\n')
            (root / 'provenance.toml').write_text('[[source]]\nname="example"\nstatus="reference-only"\n')
            img = root / 'image'
            img.mkdir()
            (img / 'nihos-native.elf').write_bytes(b'elf')
            (img / 'nihos-native.bin').write_bytes(b'app')
            (img / 'nihos-native-flash.bin').write_bytes(bytes(0x10000) + b'app')
            (img / 'image-audit.json').write_text(json.dumps({'elf_sha256': hashlib.sha256(b'elf').hexdigest(), 'image_sha256': hashlib.sha256(b'app').hexdigest(), 'memory': {'profile': 'device'}}))
            out = root / 'out'
            bom.generate(root, img, out)
            sbom = json.loads((out / 'source-sbom.cdx.json').read_text())
            cbom = json.loads((out / 'source-cbom.cdx.json').read_text())
            self.assertEqual(sbom['metadata']['component']['hashes'][0]['content'], hashlib.sha256(bytes(0x10000) + b'app').hexdigest())
            self.assertEqual(cbom['components'][0]['name'], 'X25519')
            self.assertIn({'name': 'nihos:source-location', 'value': 'src/demo.zig:1'}, cbom['components'][0]['properties'])
            rsa = next(c for c in cbom['components'] if c['name'] == 'RSA-2048')
            self.assertIn({'name': 'nihos:source-location', 'value': 'src/demo.zig:2'}, rsa['properties'])
            self.assertIn({'name': 'nihos:image-membership', 'value': 'unverified'}, rsa['properties'])
            (img / 'nihos-native-flash.bin').write_bytes(bytes(0x10000) + b'bad')
            with self.assertRaises(ValueError):
                bom.generate(root, img, out)
            (img / 'nihos-native-flash.bin').write_bytes(bytes(0x10000) + b'app')
            (img / 'nihos-native.elf').write_bytes(b'changed')
            with self.assertRaises(ValueError):
                bom.generate(root, img, out)


    def test_rsa_rule_finds_real_verifier_code(self):
        import re
        source = (bom.ROOT / 'src/card/license_crypto.zig').read_text()
        code = [line for line in source.splitlines() if not line.lstrip().startswith(('//', 'test '))]
        self.assertTrue(any(re.search(bom.PATTERNS['RSA-2048'][0], line) for line in code))

    def test_audited_input_manifests_are_checked(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / 'src').mkdir()
            (root / 'sqlite3.c').write_bytes(b'sqlite')
            sqlite_hash = hashlib.sha256(b'sqlite').hexdigest()
            fat_hash = hashlib.sha256(b'fatfs').hexdigest()
            (root / 'provenance.toml').write_text(
                '[[source]]\nname="FatFs"\nstatus="runtime"\nrevision="R0.16"\npatched_ff_c_sha256="' + fat_hash + '"\n'
                '[[source]]\nname="SQLite amalgamation"\nstatus="runtime"\nrevision="3"\n')
            # The production manifest uses a nested path ending in /sqlite3.c.
            (root / 'sqlite').mkdir()
            (root / 'sqlite' / 'sqlite3.c').write_bytes(b'sqlite')
            fs = {'upstream': {'ff.c': fat_hash}}
            sqld = {'sources': {'sqlite/sqlite3.c': sqlite_hash}}
            sqld['identity'] = hashlib.sha256(json.dumps(sqld, sort_keys=True).encode()).hexdigest()
            image = root / 'image'
            image.mkdir()
            (image / 'nihos-native.elf').write_bytes(b'elf')
            (image / 'nihos-native.bin').write_bytes(b'app')
            (image / 'nihos-native-flash.bin').write_bytes(bytes(0x10000) + b'app')
            (image / 'normal-fs-manifest.json').write_text(json.dumps(fs))
            (image / 'sqld-manifest.json').write_text(json.dumps(sqld))
            audit = {'elf_sha256': hashlib.sha256(b'elf').hexdigest(),
                     'image_sha256': hashlib.sha256(b'app').hexdigest(), 'memory': {'profile': 'device'},
                     'normal_fs': {'manifest_sha256': hashlib.sha256(json.dumps(fs, sort_keys=True, separators=(',', ':')).encode()).hexdigest()},
                     'sqld': {'identity': sqld['identity']}}
            (image / 'image-audit.json').write_text(json.dumps(audit))
            out = root / 'out'
            bom.generate(root, image, out)
            data = json.loads((out / 'audited-inputs.cdx.json').read_text())
            self.assertEqual([c['name'] for c in data['components']], ['FatFs', 'SQLite'])
            (root / 'sqlite' / 'sqlite3.c').write_bytes(b'tampered')
            with self.assertRaises(ValueError):
                bom.generate(root, image, out)


if __name__ == '__main__':
    unittest.main()
