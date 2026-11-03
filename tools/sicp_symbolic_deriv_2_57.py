#!/usr/bin/env python3
"""Exercise 2.57's MIT expression with an independently supplied solution.

Only finite examples are observed; this does not grade an entire exercise.
"""
import argparse
import hashlib
import json
from pathlib import Path
import tarfile
import xml.etree.ElementTree as ET

import sicp_abstraction_2_2_2_14 as runner
import sicp_exercise_inventory as inventory
import sicp_official_code as official

ORIGINAL = "(deriv '(* x y (+ x 3)) 'x)"
# Exercise solution: reduce a multi-operand expression to its first operand
# and the remaining expression; constructors and derivative are from MIT.
SOLUTION = '''(define (augend s)
  (if (null? (cdr (cddr s))) (caddr s) (cons '+ (cddr s))))
(define (multiplicand p)
  (if (null? (cdr (cddr p))) (caddr p) (cons '* (cddr p))))'''


def original_setup():
    if hashlib.sha256(official.ARCHIVE.read_bytes()).hexdigest() != official.SHA256:
        raise ValueError('MIT archive hash mismatch')
    if hashlib.sha256(inventory.ARCHIVE.read_bytes()).hexdigest() != inventory.SHA256:
        raise ValueError('XML archive hash mismatch')
    with tarfile.open(inventory.ARCHIVE, 'r:gz') as archive:
        xml = ET.fromstring(archive.extractfile('xml/chapter2/section3/subsection2.xml').read())
    if 'ex:2_57' not in {node.get('NAME') for node in xml.iter('LABEL')}:
        raise ValueError('exercise 2.57 XML label missing')
    with tarfile.open(official.ARCHIVE, 'r:gz') as archive:
        code = archive.extractfile('ch2.scm').read().decode('ascii')
    part = code.split(';;;SECTION 2.3.2\n', 1)[1]
    definitions, after = part.split(';; EXERCISE 2.57', 1)
    if ';: ' + ORIGINAL not in after:
        raise ValueError('original exercise expression missing')
    # Chibi's default environment lacks (scheme cxr). This compatibility
    # definition has the same meaning as R7RS caddr, which xy already provides.
    return '(define (caddr x) (car (cdr (cdr x))))\n' + definitions + '\n' + SOLUTION


def cases():
    setup = original_setup()
    samples = [
        (ORIGINAL, '(+ (* x y) (* y (+ x 3)))', 'MIT exercise expression'),
        ("(deriv '(+ x x x) 'x)", '3', 'additional finite example'),
        ("(deriv '(* x y (+ x 3)) 'y)", '(* x (+ x 3))', 'additional finite example'),
    ]
    return [dict(exercise='2.57', setup=setup, expression=expression,
                 expected=expected, source=source, sequential_setup=True)
            for expression, expected, source in samples]


def run(zig, chibi):
    result = runner.run(zig, chibi, case_builder=cases, source_verifier=lambda: None)
    result['note'] = ('MIT original derivative and 2.57 expression; our n-ary selectors; '
                      'finite examples, not a full exercise grade.')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--zig', type=Path, required=True)
    parser.add_argument('--chibi', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(run(args.zig, args.chibi), indent=2))
