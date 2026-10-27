#!/usr/bin/env python3
"""Generate synthetic NPA RSA vectors; discard private keys, never install trust.

Explicit fresh output directory required. Random keys intentionally produce new
hashes. Checked-in vectors are identified by their adjacent provenance hashes.
"""
import argparse,hashlib,json
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric import rsa
def sign(key,data):
    digest=hashlib.sha256(data).digest();block=b'\0\1'+b'\xff'*221+b'\0'+digest
    return pow(int.from_bytes(block,'big'),key.d,key.public_numbers.n).to_bytes(256,'big')
def tlv(tag,value):return tag+(bytes([len(value)]) if len(value)<128 else b'\x82'+len(value).to_bytes(2,'big'))+value
def file(data,size):
    if len(data)>size:raise ValueError('fixture too large')
    return data.ljust(size,b'\xff')
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('output',type=Path);a=p.parse_args();a.output.mkdir(exist_ok=False)
    key=rsa.generate_private_key(public_exponent=65537,key_size=2048).private_numbers();modulus=key.public_numbers.n.to_bytes(256,'big')
    message=b'nihOS synthetic licence';digest=hashlib.sha256(message).digest();info=bytes.fromhex('3031300d060960864801650304020105000420')+digest
    standard=b'\0\1'+b'\xff'*(253-len(info))+b'\0'+info;bad=bytearray(b'\0\1'+b'\xff'*221+b'\0'+digest);bad[17]=0
    signed=lambda block:pow(int.from_bytes(block,'big'),key.d,key.public_numbers.n).to_bytes(256,'big')
    third=rsa.generate_private_key(public_exponent=3,key_size=2048).private_numbers()
    vector=modulus+sign(key,message)+signed(standard)+signed(bad)+third.public_numbers.n.to_bytes(256,'big')+sign(third,message)
    name='山田'.encode('iso2022_jp')[3:-3];address='東京'.encode('iso2022_jp')[3:-3]
    common=file(tlv(b'\x12',name)+tlv(b'\x17',address)+tlv(b'\x16',b'4020108')+tlv(b'\x1b',b'5120101')+tlv(b'\x21',b'000000000000'),880)
    domicile=file(tlv(b'\x41',address),82);photo=file(tlv(b'\x5f\x40',b'\xff\x4f0123456789abcd'),2005)
    myna=file(tlv(b'\xc5',b'5120101')+tlv(b'\xe7',b'000000000000')+tlv(b'\xed',b'\1')+tlv(b'\xff\x07',b'\xff\x4f0123456789abcd'),5845)
    kid=hashlib.sha256(modulus).digest()
    classic=common+domicile+photo;classic_signature=file(tlv(b'\xb1',sign(key,classic))+tlv(b'\xb6',kid),578)
    myna_signature=file(tlv(b'\xff\x08',sign(key,myna))+tlv(b'\xff\x0d',kid),584)
    for name,data in [('license-rsa.bin',vector),('license-verification.bin',modulus+kid+classic+classic_signature+myna+myna_signature)]:
        path=a.output/name;path.write_bytes(data);path.with_suffix('.json').write_text(json.dumps({'synthetic':True,'production_trust_anchor':False,'generator':'tools/generate-license-fixtures.py; Python cryptography key generation + independent Python integer exponentiation; private keys discarded','sha256':hashlib.sha256(data).hexdigest()},indent=2)+'\n')
if __name__=='__main__':main()
