import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import supply_chain_bom as bom


def make_image(image):
    image.mkdir()
    for name in ('bootloader', 'partition_table', 'config'):
        (image / 'loader' / name).mkdir(parents=True)
    files = {'nihos-native.elf': b'elf', 'nihos-native.bin': b'app',
             'loader/bootloader/bootloader.bin': b'boot',
             'loader/bootloader/bootloader.elf': b'loader elf',
             'loader/partition_table/partition-table.bin': b'partition',
             'loader/config/sdkconfig.h': b'config'}
    for name, data in files.items():
        (image / name).write_bytes(data)
    flash = bytearray(b'\xff' * 0x10000 + b'app')
    flash[0x2000:0x2004] = b'boot'
    flash[0x8000:0x8009] = b'partition'
    (image / 'nihos-native-flash.bin').write_bytes(flash)
    h = lambda data: hashlib.sha256(data).hexdigest()
    return {'elf_sha256': h(b'elf'), 'image_sha256': h(b'app'),
            'loader': {'elf_sha256': h(b'loader elf')},
            'loader_config': {'config_sha256': h(b'config')},
            'memory': {'profile': 'device'}}


class BomTest(unittest.TestCase):
    def test_candidates_and_image_binding(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / 'src').mkdir()
            (root / 'src' / 'demo.zig').write_text('const X = std.crypto.dh.X25519;\nconst M = std.crypto.ff.Modulus(2048);\n')
            (root / 'provenance.toml').write_text('[[source]]\nname="example"\nstatus="reference-only"\n')
            img = root / 'image'
            audit = make_image(img)
            (img / 'image-audit.json').write_text(json.dumps(audit))
            out = root / 'out'
            receipt = {'schema': 1, 'zig_version': '0.17.0', 'zig_sha256': 'a' * 64,
                       'idf_commit': bom.native_build_tool_evidence.IDF_COMMIT, 'idf_tracked_clean': True}
            bom.generate(root, img, out, receipt)
            for name in ('source-sbom.cdx.json', 'source-cbom.cdx.json', 'audited-inputs.cdx.json'):
                metadata = json.loads((out / name).read_text())['metadata']
                entries = [p['value'] for p in metadata['properties'] if p['name'] == 'nihos:build-tool-evidence']
                self.assertEqual(json.loads(entries[0]), receipt)
            sbom = json.loads((out / 'source-sbom.cdx.json').read_text())
            cbom = json.loads((out / 'source-cbom.cdx.json').read_text())
            self.assertEqual(sbom['metadata']['component']['hashes'][0]['content'], hashlib.sha256((img / 'nihos-native-flash.bin').read_bytes()).hexdigest())
            self.assertEqual(cbom['components'][0]['name'], 'X25519')
            self.assertIn({'name': 'nihos:source-location', 'value': 'src/demo.zig:1'}, cbom['components'][0]['properties'])
            rsa = next(c for c in cbom['components'] if c['name'] == 'RSA-2048')
            self.assertIn({'name': 'nihos:source-location', 'value': 'src/demo.zig:2'}, rsa['properties'])
            self.assertIn({'name': 'nihos:image-membership', 'value': 'unverified'}, rsa['properties'])
            flash = (img / 'nihos-native-flash.bin').read_bytes()
            for offset in (0x2000, 0x8000, 0x10000, 0):
                altered = bytearray(flash)
                altered[offset] ^= 1
                (img / 'nihos-native-flash.bin').write_bytes(altered)
                with self.assertRaises(ValueError):
                    bom.generate(root, img, out)
            for altered in (flash[:-1], flash + b'\xff'):
                (img / 'nihos-native-flash.bin').write_bytes(altered)
                with self.assertRaises(ValueError):
                    bom.generate(root, img, out)
            (img / 'nihos-native-flash.bin').write_bytes(flash)
            for path in ('nihos-native.elf', 'loader/bootloader/bootloader.elf',
                         'loader/config/sdkconfig.h'):
                target = img / path
                original = target.read_bytes()
                target.write_bytes(b'changed')
                with self.assertRaises(ValueError):
                    bom.generate(root, img, out)
                target.write_bytes(original)



    def test_rsa_rule_finds_real_verifier_code(self):
        import re
        source = (bom.ROOT / 'src/card/license_crypto.zig').read_text()
        code = [line for line in source.splitlines() if not line.lstrip().startswith(('//', 'test '))]
        self.assertTrue(any(re.search(bom.PATTERNS['RSA-2048'][0], line) for line in code))

    def test_rsa_link_evidence_requires_audited_profile_and_source(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / 'src/card').mkdir(parents=True)
            source = root / 'src/card/license_crypto.zig'
            source.write_text('const M = std.crypto.ff.Modulus(2048);\n')
            (root / 'provenance.toml').write_text('[[source]]\nname="test"\nstatus="runtime"\n')
            image = root / 'image'
            audit = make_image(image)
            manifest = {'sources': {'src/card/license_crypto.zig': bom.digest(source)},
                        'automatic_cards': {'read_enabled': True},
                        'license_crypto': {'profile': 'npa-raw-sha256-v1_5', 'bits': 2048,
                                           'allowed_functions': ['nih_card_crypto']}}
            def write_audit():
                (image / 'photo-manifest.json').write_text(json.dumps(manifest))
                (image / 'image-audit.json').write_text(json.dumps(audit))
            audit['photo_codec'] = {'manifest_sha256': hashlib.sha256(json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode()).hexdigest(),
                'card_rsa_link_evidence': {'function': 'nih_card_crypto', 'function_address': '0x4000',
                                            'function_bytes': 12, 'profile': 'npa-raw-sha256-v1_5', 'bits': 2048}}
            write_audit()
            out = root / 'out'
            bom.generate(root, image, out)
            rsa = next(c for c in json.loads((out / 'source-cbom.cdx.json').read_text())['components'] if c['name'] == 'RSA-2048')
            self.assertIn({'name': 'nihos:linked-function', 'value': 'nih_card_crypto'}, rsa['properties'])
            source.write_text('const M = std.crypto.ff.Modulus(2048); // modified\n')
            with self.assertRaises(ValueError):
                bom.generate(root, image, out)
            source.write_text('const M = std.crypto.ff.Modulus(2048);\n')
            manifest['automatic_cards']['read_enabled'] = False
            audit['photo_codec']['manifest_sha256'] = hashlib.sha256(json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
            write_audit()
            with self.assertRaises(ValueError):
                bom.generate(root, image, out)
            del audit['photo_codec']['card_rsa_link_evidence']
            write_audit()
            bom.generate(root, image, out)
            rsa = next(c for c in json.loads((out / 'source-cbom.cdx.json').read_text())['components'] if c['name'] == 'RSA-2048')
            self.assertIn({'name': 'nihos:image-membership', 'value': 'unverified'}, rsa['properties'])

    def test_audited_input_manifests_are_checked(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / 'src').mkdir()
            sqlite_source = b'static void chacha_block(\nSQLITE_API void sqlite3_randomness(\nchacha20_init[]\nchacha_block((u32*)wsdPrng.out, wsdPrng.s);\n'
            sqlite_hash = hashlib.sha256(sqlite_source).hexdigest()
            fat_hash = hashlib.sha256(b'fatfs').hexdigest()
            (root / 'provenance.toml').write_text(
                '[[source]]\nname="FatFs"\nstatus="runtime"\nrevision="R0.16"\npatched_ff_c_sha256="' + fat_hash + '"\n'
                '[[source]]\nname="SQLite amalgamation"\nstatus="runtime"\nrevision="3"\n')
            # The production manifest uses a nested path ending in /sqlite3.c.
            (root / 'sqlite').mkdir()
            (root / 'sqlite' / 'sqlite3.c').write_bytes(sqlite_source)
            fs = {'upstream': {'ff.c': fat_hash}}
            sqld = {'sources': {'sqlite/sqlite3.c': sqlite_hash}}
            sqld['identity'] = hashlib.sha256(json.dumps(sqld, sort_keys=True).encode()).hexdigest()
            image = root / 'image'
            audit = make_image(image)
            (image / 'normal-fs-manifest.json').write_text(json.dumps(fs))
            (image / 'sqld-manifest.json').write_text(json.dumps(sqld))
            audit.update({'normal_fs': {'manifest_sha256': hashlib.sha256(json.dumps(fs, sort_keys=True, separators=(',', ':')).encode()).hexdigest()},
                          'sqld': {'identity': sqld['identity'], 'sqlite_prng_link_evidence': {'function': 'sqlite3_randomness', 'function_address': '0x4008', 'function_bytes': 16, 'constant': 'sqlite3_randomness.chacha20_init', 'constant_address': '0x5004'}}})
            (image / 'image-audit.json').write_text(json.dumps(audit))
            out = root / 'out'
            bom.generate(root, image, out)
            cbom = json.loads((out / 'source-cbom.cdx.json').read_text())
            candidate = next(c for c in cbom['components'] if c['name'] == 'ChaCha20')
            self.assertIn({'name': 'nihos:linked-function', 'value': 'sqlite3_randomness'}, candidate['properties'])
            del audit['sqld']['sqlite_prng_link_evidence']
            (image / 'image-audit.json').write_text(json.dumps(audit))
            bom.generate(root, image, out)
            self.assertFalse(any(c['name'] == 'ChaCha20' for c in json.loads((out / 'source-cbom.cdx.json').read_text())['components']))
            data = json.loads((out / 'audited-inputs.cdx.json').read_text())
            self.assertEqual([c['name'] for c in data['components']], ['bootloader.bin', 'partition-table.bin', 'nihos-native.bin', 'FatFs', 'SQLite'])
            for component, payload, offset in zip(data['components'][:3], (b'boot', b'partition', b'app'), ('0x2000', '0x8000', '0x10000')):
                self.assertEqual(component['hashes'][0]['content'], hashlib.sha256(payload).hexdigest())
                self.assertIn({'name': 'nihos:flash-offset', 'value': offset}, component['properties'])
                self.assertIn({'name': 'nihos:flash-size-bytes', 'value': str(len(payload))}, component['properties'])
            (root / 'sqlite' / 'sqlite3.c').write_bytes(b'tampered')
            with self.assertRaises(ValueError):
                bom.generate(root, image, out)


if __name__ == '__main__':
    unittest.main()
