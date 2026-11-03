#!/usr/bin/env python3
"""Finite SICP 2.67 decoding observations using MIT's original code/data."""
import argparse
import hashlib
import json
from pathlib import Path
import tarfile
import xml.etree.ElementTree as ET

import sicp_abstraction_2_2_2_14 as runner
import sicp_exercise_inventory as inventory
import sicp_official_code as official


def original_setup():
    if hashlib.sha256(official.ARCHIVE.read_bytes()).hexdigest() != official.SHA256:
        raise ValueError('MIT archive hash mismatch')
    if hashlib.sha256(inventory.ARCHIVE.read_bytes()).hexdigest() != inventory.SHA256:
        raise ValueError('XML archive hash mismatch')
    with tarfile.open(inventory.ARCHIVE, 'r:gz') as archive:
        xml = ET.fromstring(archive.extractfile('xml/chapter2/section3/subsection4.xml').read())
    if 'ex:sample-tree' not in {node.get('NAME') for node in xml.iter('LABEL')}:
        raise ValueError('exercise 2.67 XML label missing')
    with tarfile.open(official.ARCHIVE, 'r:gz') as archive:
        code = archive.extractfile('ch2.scm').read().decode('ascii')
    section = code.split(';;;SECTION 2.3.3\n\n;; representing', 1)[1]
    definitions, after = section.split(';; EXERCISE 2.67', 1)
    examples = after.split(';; EXERCISE 2.68', 1)[0]
    sample = '\n'.join(line.removeprefix(';: ') for line in examples.splitlines() if line.startswith(';: '))
    if not all(marker in sample for marker in ('(define sample-tree', '(define sample-message', "'(0 1 1 0 0 1 0 1 0 1 1 1 0)")):
        raise ValueError('original MIT sample missing')
    # Chibi's default environment lacks (scheme cxr); xy supplies these.
    compatibility = '(define (caddr x) (car (cdr (cdr x))))\n(define (cadddr x) (car (cdr (cdr (cdr x)))))\n'
    return compatibility + definitions + '\n' + sample


def cases():
    setup = original_setup()
    samples = [
        ('(decode sample-message sample-tree)', '(A D A B B C A)', 'MIT sample'),
        ("(decode '() sample-tree)", '()', 'additional finite example'),
        ("(decode '(1 1 1 0 1 0) sample-tree)", '(C A B)', 'additional finite example'),
    ]
    return [dict(exercise='2.67', setup=setup, expression=source, expected=expected,
                 source=origin, sequential_setup=True)
            for source, expected, origin in samples]


def run(zig, chibi):
    result = runner.run(zig, chibi, case_builder=cases, source_verifier=lambda: None)
    result['note'] = 'MIT Huffman decoder and sample; finite decoding observations only.'
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--zig', type=Path, required=True)
    parser.add_argument('--chibi', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(run(args.zig, args.chibi), indent=2))
