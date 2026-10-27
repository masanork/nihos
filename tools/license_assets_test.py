"""Pinned assets must preserve glyphs and reject unreviewed certificate inputs."""
import datetime,hashlib,importlib.util,json,tempfile,unittest
from pathlib import Path
def module(name,file):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(file));value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
FONT=module('row_font','font_codec.py');TRUST=module('licence_pins','import-license-trust.py')
ROOT=Path(__file__).resolve().parents[1]
class Assets(unittest.TestCase):
    def test_every_pinned_glyph_round_trips_and_offsets_are_canonical(self):
        raw=(ROOT/'src/graphics/card_read_font.bin').read_bytes();encoded=(ROOT/'src/graphics/card_auto_font.bin').read_bytes()
        self.assertEqual(FONT.decode(encoded),raw);self.assertEqual(FONT.encode(raw),encoded)
        manifest=json.loads((ROOT/'src/graphics/card_auto_font.json').read_text());self.assertEqual(hashlib.sha256(raw).hexdigest(),manifest['font_raw_sha256'])
        for at,value in [(0,0),(10,11),(12+4095*2+3,1)]:
            altered=bytearray(encoded);altered[at]=value
            with self.assertRaises(ValueError):FONT.decode(altered)
        for altered in (encoded[:-1],encoded+b'\0'):
            with self.assertRaises(ValueError):FONT.decode(altered)
    def test_certificate_pins_require_hash_provenance_unique_ski_and_rsa2048(self):
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes,serialization
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.x509.oid import NameOID
        key=rsa.generate_private_key(public_exponent=65537,key_size=2048);name=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'SYNTHETIC TEST ONLY')]);now=datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
        cert=x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key()).serial_number(1).not_valid_before(now-datetime.timedelta(days=1)).not_valid_after(now+datetime.timedelta(days=1)).add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()),False).sign(key,hashes.SHA256()).public_bytes(serialization.Encoding.DER)
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);(root/'test.der').write_bytes(cert);item={'certificate':'test.der','sha256':hashlib.sha256(cert).hexdigest(),'source':'synthetic local test; never production trust'}
            data,metadata=TRUST.encode([item],root);self.assertEqual(len(data),293);self.assertEqual(len(metadata),1)
            for items in ([],[dict(item,sha256='0'*64)],[dict(item,source='')],[item,item]):
                with self.assertRaises(ValueError):TRUST.encode(items,root)
        self.assertEqual((ROOT/'src/card/license_trust.bin').read_bytes(),b'')
if __name__=='__main__':unittest.main()
