#!/usr/bin/env python3
"""Finite SICP 2.63-2.64 observations using the MIT binary-tree code."""
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
        xml = ET.fromstring(archive.extractfile('xml/chapter2/section3/subsection3.xml').read())
    labels = {node.get('NAME') for node in xml.iter('LABEL')}
    if not {'ex:tree-to-list', 'ex:list-to-tree'} <= labels:
        raise ValueError('exercise XML labels missing')
    with tarfile.open(official.ARCHIVE, 'r:gz') as archive:
        code = archive.extractfile('ch2.scm').read().decode('ascii')
    definitions = code.split(';; BINARY TREES', 1)[1].split(';; INFORMATION RETRIEVAL', 1)[0]
    if not all(marker in definitions for marker in (';; EXERCISE 2.63', ';; EXERCISE 2.64', '(define (partial-tree elts n)')):
        raise ValueError('MIT exercise definitions missing')
    # The default Chibi environment lacks (scheme cxr); xy supplies caddr.
    return '(define (caddr x) (car (cdr (cdr x))))\n' + definitions


def cases():
    setup = original_setup()
    examples = [
        "(7 (3 (1 () ()) (5 () ())) (9 () (11 () ())))",
        "(3 (1 () ()) (7 (5 () ()) (9 () (11 () ()))))",
        "(5 (3 (1 () ()) ()) (9 (7 () ()) (11 () ())))",
    ]
    rows = []
    for tree in examples:
        for procedure in ('tree->list-1', 'tree->list-2'):
            rows.append(dict(exercise='2.63', setup=setup, expression=f"({procedure} '{tree})",
                             expected='(1 3 5 7 9 11)', sequential_setup=True))
    for source, answer in [
        ("(list->tree '())", '()'),
        ("(list->tree '(7))", '(7 () ())'),
        ("(list->tree '(1 3 5 7 9 11))", '(5 (1 () (3 () ())) (9 (7 () ()) (11 () ())))'),
        ("(tree->list-2 (list->tree '(1 3 5 7 9 11)))", '(1 3 5 7 9 11)'),
    ]:
        rows.append(dict(exercise='2.64', setup=setup, expression=source,
                         expected=answer, sequential_setup=True))
    return rows


def run(zig, chibi):
    result = runner.run(zig, chibi, case_builder=cases, source_verifier=lambda: None)
    result['note'] = ('MIT binary-tree and exercise procedures; finite authored inputs, '
                      'not full solutions or complexity proofs.')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--zig', type=Path, required=True)
    parser.add_argument('--chibi', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(run(args.zig, args.chibi), indent=2))
