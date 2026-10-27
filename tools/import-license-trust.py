#!/usr/bin/env python3
"""Build pinned RSA public-key records from explicitly identified X.509 certificates.

Input: JSON list [{certificate, sha256, source}]. Fingerprints and trusted-source
provenance must be supplied out of band. Does not fetch or trust card content.
"""
import argparse,hashlib,json
from pathlib import Path
from cryptography import x509
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import ExtensionOID
def encode(items,root):
    if not isinstance(items,list) or not 1<=len(items)<=64:raise ValueError('1..64 explicit certificates required')
    records=[];seen=set();metadata=[]
    for item in items:
        raw=(root/item['certificate']).read_bytes()
        actual=hashlib.sha256(raw).hexdigest()
        if actual!=item['sha256'] or not isinstance(item['source'],str) or not item['source'].strip():raise ValueError('fingerprint or provenance missing/mismatched')
        cert=x509.load_pem_x509_certificate(raw) if raw.startswith(b'-----BEGIN') else x509.load_der_x509_certificate(raw)
        key=cert.public_key()
        if not isinstance(key,rsa.RSAPublicKey) or key.key_size!=2048:raise ValueError('RSA-2048 certificate required')
        identifier=cert.extensions.get_extension_for_oid(ExtensionOID.SUBJECT_KEY_IDENTIFIER).value.digest
        if not 1<=len(identifier)<=32 or identifier in seen:raise ValueError('missing/duplicate/oversized key identifier')
        seen.add(identifier);numbers=key.public_numbers()
        if numbers.e not in (3,65537):raise ValueError('invalid public exponent')
        records.append(bytes([len(identifier)])+identifier.ljust(32,b'\0')+numbers.n.to_bytes(256,'big')+numbers.e.to_bytes(4,'big'))
        before=cert.not_valid_before_utc if hasattr(cert,'not_valid_before_utc') else cert.not_valid_before
        after=cert.not_valid_after_utc if hasattr(cert,'not_valid_after_utc') else cert.not_valid_after
        metadata.append({'certificate_sha256':actual,'source':item['source'],'key_id':identifier.hex(),'not_before':str(before),'not_after':str(after)})
    return b''.join(records),metadata
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('input',type=Path);p.add_argument('output',type=Path);a=p.parse_args()
    data,certs=encode(json.loads(a.input.read_text()),a.input.parent)
    a.output.write_bytes(data);a.output.with_suffix('.json').write_text(json.dumps({'schema':1,'records':len(certs),'record_bytes':293,'sha256':hashlib.sha256(data).hexdigest(),'trust_model':'explicit certificate pins; no runtime chain, expiry or revocation checks','certificates':certs},indent=2)+'\n')
if __name__=='__main__':main()
