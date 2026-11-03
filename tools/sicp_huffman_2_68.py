#!/usr/bin/env python3
"""Finite SICP 2.68 Huffman encoding checks using MIT code and sample data."""
import argparse
import json
from pathlib import Path
import tarfile
import xml.etree.ElementTree as ET

import sicp_abstraction_2_2_2_14 as runner
import sicp_exercise_inventory as inventory
import sicp_huffman_2_67 as prior
import sicp_official_code as official

# This exercise asks the reader to supply encode-symbol; this solution is ours.
SOLUTION = '''(define (encode-symbol symbol tree)
  (cond ((leaf? tree) (if (eq? symbol (symbol-leaf tree)) '() (error "unknown symbol" symbol)))
        ((memq symbol (symbols (left-branch tree)))
         (cons 0 (encode-symbol symbol (left-branch tree))))
        ((memq symbol (symbols (right-branch tree)))
         (cons 1 (encode-symbol symbol (right-branch tree))))
        (else (error "unknown symbol" symbol))))'''


def original_setup():
    setup = prior.original_setup()  # Verifies both pinned source archives.
    with tarfile.open(inventory.ARCHIVE, 'r:gz') as archive:
        xml = ET.fromstring(archive.extractfile('xml/chapter2/section3/subsection4.xml').read())
    if 'ex:encode-symbol' not in {node.get('NAME') for node in xml.iter('LABEL')}:
        raise ValueError('exercise 2.68 XML label missing')
    with tarfile.open(official.ARCHIVE, 'r:gz') as archive:
        code = archive.extractfile('ch2.scm').read().decode('ascii')
    encode = code.split(';; EXERCISE 2.68', 1)[1].split(';; EXERCISE 2.69', 1)[0]
    if '(define (encode message tree)' not in encode:
        raise ValueError('MIT encoder missing')
    return setup + '\n' + encode + '\n' + SOLUTION


def cases():
    setup = original_setup()
    samples = [
        ('(encode (decode sample-message sample-tree) sample-tree)', '(0 1 1 0 0 1 0 1 0 1 1 1 0)'),
        ("(encode '() sample-tree)", '()'),
        ("(encode '(A B C D) sample-tree)", '(0 1 0 1 1 1 1 1 0)'),
    ]
    return [dict(exercise='2.68', setup=setup, expression=source,
                 expected=expected, sequential_setup=True) for source, expected in samples]


def run(zig, chibi):
    result = runner.run(zig, chibi, case_builder=cases, source_verifier=lambda: None)
    result['note'] = 'MIT encoder and sample data; independently supplied encode-symbol; finite cases only.'
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--zig', type=Path, required=True)
    parser.add_argument('--chibi', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(run(args.zig, args.chibi), indent=2))
