#!/usr/bin/env python3
"""Verify and inventory MIT Press's complete original SICP code archive.

This reads archive members in memory without extracting paths or executing code.
The chapter files contain redefinitions and disabled examples, so inventory is
not equivalent to tests or a claim that exercises have passed.
"""
import hashlib
import io
import json
from pathlib import Path
import tarfile

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / 'third_party/sicp-corpus/mit-allcode.tar.gz'
SHA256 = '9ac51401a7e57c497f5d68998942bde4751f612b094b52d7dda17f4ba23a18fd'
NAMES = frozenset('''ch1.scm ch2.scm ch2support.scm ch2tests.scm ch3.scm ch3support.scm
ch4-ambeval.scm ch4-analyzingmceval.scm ch4-leval.scm ch4-mceval.scm ch4-query.scm ch4.scm
ch5-compiler.scm ch5-eceval-compiler.scm ch5-eceval-support.scm ch5-eceval.scm
ch5-regsim.scm ch5-syntax.scm ch5.scm load-eceval-compiler.scm load-eceval.scm'''.split())


def inventory(path=ARCHIVE):
    raw = Path(path).read_bytes()
    if hashlib.sha256(raw).hexdigest() != SHA256:
        raise ValueError('MIT SICP archive hash mismatch')
    entries = {}
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as archive:
        for member in archive:
            if not member.isfile() or member.name not in NAMES or member.name in entries:
                raise ValueError('unexpected MIT SICP archive member')
            source = archive.extractfile(member).read()
            entries[member.name] = {'bytes': len(source), 'sha256': hashlib.sha256(source).hexdigest()}
    if entries.keys() != NAMES:
        raise ValueError('MIT SICP archive is incomplete')
    return dict(sorted(entries.items()))


if __name__ == '__main__':
    print(json.dumps({'source': 'MIT Press SICP second edition code archive',
                      'archive_sha256': SHA256, 'files': inventory()}, indent=2))
