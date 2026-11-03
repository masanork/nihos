#!/usr/bin/env python3
"""Finite checks of original SICP exercises 4.8 and 4.20."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import tarfile
import xml.etree.ElementTree as ET

import sicp_abstraction_2_2_2_14 as runner
import sicp_exercise_inventory as inv
import sicp_official_code as official


def original_example():
    archive = inv.ARCHIVE.read_bytes()
    if hashlib.sha256(archive).hexdigest() != inv.SHA256:
        raise ValueError('XML archive hash mismatch')
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as tar:
        root = ET.fromstring(tar.extractfile('xml/chapter4/section1/subsection2.xml').read())
    exercises = [e for e in root.iter('EXERCISE')
                 if any(n.get('NAME') == 'ex:named-let' for n in e.iter('LABEL'))]
    if len(exercises) != 1:
        raise ValueError('named-let exercise not found uniquely')
    snippets = [''.join(n.itertext()).strip() for n in exercises[0].findall('.//SNIPPET/SCHEME')]
    matches = [s for s in snippets if s.startswith('(define (fib n)') and '(let fib-iter' in s]
    if len(matches) != 1:
        raise ValueError('original named-let example not found uniquely')
    return matches[0]


def factorial_example():
    archive = inv.ARCHIVE.read_bytes()
    if hashlib.sha256(archive).hexdigest() != inv.SHA256:
        raise ValueError('XML archive hash mismatch')
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as tar:
        root = ET.fromstring(tar.extractfile('xml/chapter4/section1/subsection6.xml').read())
    exercises = [e for e in root.iter('EXERCISE')
                 if any(n.get('NAME') == 'ex:letrec' for n in e.iter('LABEL'))]
    if len(exercises) != 1:
        raise ValueError('letrec exercise not found uniquely')
    snippets = [''.join(n.itertext()).strip() for n in exercises[0].findall('.//SNIPPET/SCHEME')]
    matches = [s for s in snippets if s.startswith('(letrec ((fact') and '(fact 10)' in s]
    if len(matches) != 1:
        raise ValueError('original letrec example not found uniquely')
    return matches[0]


def cases():
    source = original_example()
    # Independent finite expected values. This does not implement the exercise's
    # requested metacircular evaluator transformation.
    rows = [dict(exercise='4.8', setup=source, expression=f'(fib {n})', expected=str(value))
            for n, value in ((0, 0), (1, 1), (2, 1), (5, 5), (10, 55), (20, 6765), (30, 832040))]
    rows.append(dict(exercise='4.20', setup='', expression=factorial_example(), expected='3628800'))
    return rows


def verify_sources():
    original_example()
    factorial_example()
    if hashlib.sha256(official.ARCHIVE.read_bytes()).hexdigest() != official.SHA256:
        raise ValueError('MIT code archive hash mismatch')
    official.inventory(official.ARCHIVE)


def run(zig, chibi):
    result = runner.run(zig, chibi, case_builder=cases, source_verifier=verify_sources)
    result['note'] = 'Original 4.8 named-let Fibonacci example on finite inputs and 4.20 factorial expression; evaluator transformations remain untested.'
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--zig', type=Path, required=True)
    parser.add_argument('--chibi', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(run(args.zig, args.chibi), indent=2))
