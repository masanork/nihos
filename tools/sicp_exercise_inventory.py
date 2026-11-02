#!/usr/bin/env python3
"""Inventory Scheme exercise nodes in the pinned SICP source, without running them."""
import hashlib
import json
from pathlib import Path
import re
import tarfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / 'third_party/sicp-corpus/xml.tar.gz'
SHA256 = '02ac17ebbfeabefff177775c2b608fe008a62cb0cfcc34d4e526c83f453c9621'
SKIP = {'JAVASCRIPT', 'JAVASCRIPT_ONLY', 'JAVASCRIPTINLINE', 'SOLUTION', 'WEB_ONLY'}


def natural(value):
    return [int(x) if x.isdigit() else x for x in re.split(r'(\d+)', value)]


def exercise_nodes(node):
    if node.tag in SKIP:
        return
    if node.tag == 'EXERCISE':
        yield node
        return
    for child in node:
        yield from exercise_nodes(child)


def inventory(path=ARCHIVE):
    raw = Path(path).read_bytes()
    if hashlib.sha256(raw).hexdigest() != SHA256:
        raise ValueError('SICP source archive hash mismatch')
    results = []
    with tarfile.open(fileobj=__import__('io').BytesIO(raw), mode='r:gz') as archive:
        members = sorted((m for m in archive if m.isfile() and m.name.endswith('.xml')), key=lambda m: natural(m.name))
        for member in members:
            # No archive member is extracted to the filesystem.
            root = ET.fromstring(archive.extractfile(member).read())
            for index, node in enumerate(exercise_nodes(root), 1):
                labels = [n.get('NAME') for n in node.findall('./LABEL') if n.get('NAME')]
                status = ('excluded_non_scheme' if member.name == 'xml/chapter4/section1/subsection3.xml'
                          and 'ex:access_unassigned' in labels else 'unreviewed')
                results.append({'source': member.name, 'ordinal_in_file': index,
                                'labels': labels, 'status': status,
                                'book_number': None})
    return results


if __name__ == '__main__':
    print(json.dumps({'source_commit': '35b1a2274eec60046772dd0a4ea80021369226fc',
                      'archive_sha256': SHA256, 'exercises': inventory()}, indent=2))
