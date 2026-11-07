#!/usr/bin/env python3
"""Independently reproduce the fixed, non-secret SSH authentication vector."""
import hashlib
import struct
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def string(data):
    return struct.pack('>I', len(data)) + data


def main():
    session = bytes([0x24]) * 32
    key = Ed25519PrivateKey.from_private_bytes(bytes([0x42]) * 32)
    public = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    public_blob = string(b'ssh-ed25519') + string(public)
    prefix = (b'\x32' + string(b'fixture') + string(b'ssh-connection') + string(b'publickey')
              + b'\x01' + string(b'ssh-ed25519') + string(public_blob))
    signed = string(session) + prefix
    signature = key.sign(signed)
    key.public_key().verify(signature, signed)
    for changed in (string(bytes([0x25]) * 32) + prefix, signed[:-1] + bytes([signed[-1] ^ 1])):
        try:
            key.public_key().verify(signature, changed)
        except InvalidSignature:
            continue
        raise SystemExit('modified signed data unexpectedly verified')
    payload = prefix + string(string(b'ssh-ed25519') + string(signature))
    digest = hashlib.sha256(payload).hexdigest()
    assert len(payload) == 201
    assert public.hex() == '2152f8d19b791d24453242e15f2eab6cb7cffa7b6a5ed30097960e069881db12'
    assert digest == '04b2fbeac6ba3b1081d5b910f1bceb269e4514a07c37689d80ce4f60c6edae0d'
    print('SSH Ed25519 fixture reference and modified-message rejection passed:', digest)


if __name__ == '__main__':
    main()
