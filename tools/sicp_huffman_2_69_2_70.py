#!/usr/bin/env python3
"""Finite SICP 2.69/2.70 Huffman observations, including resource failures."""
import argparse
import json
from pathlib import Path
import tarfile
import xml.etree.ElementTree as ET

import sicp_abstraction_2_2_2_14 as runner
import sicp_exercise_inventory as inventory
import sicp_huffman_2_68 as prior
import sicp_official_code as official

# The MIT exercise asks the reader to supply successive-merge.
SOLUTION = '''(define (successive-merge leaves)
  (if (null? leaves) '()
      (if (null? (cdr leaves)) (car leaves)
          (successive-merge
           (adjoin-set (make-code-tree (car leaves) (cadr leaves)) (cddr leaves))))))'''


def original_data():
    setup = prior.original_setup()  # Validates the pinned MIT and XML archives.
    with tarfile.open(official.ARCHIVE, 'r:gz') as archive:
        code = archive.extractfile('ch2.scm').read().decode('ascii')
    generate = code.split(';; EXERCISE 2.69', 1)[1].split(';;;SECTION 2.4.1', 1)[0].strip()
    if '(define (generate-huffman-tree pairs)' not in generate:
        raise ValueError('MIT tree generator missing')
    with tarfile.open(inventory.ARCHIVE, 'r:gz') as archive:
        xml = ET.fromstring(archive.extractfile('xml/chapter2/section3/subsection4.xml').read())
    labels = {node.get('NAME') for node in xml.iter('LABEL')}
    if not {'ex:generate-huffman-tree', 'ex:2_70'} <= labels:
        raise ValueError('exercise labels missing')
    exercises = [node for node in xml.iter('EXERCISE')
                 if any(label.get('NAME') == 'ex:2_70' for label in node.iter('LABEL'))]
    if len(exercises) != 1:
        raise ValueError('expected one original song exercise')
    tables = list(exercises[0].iter('TABLE'))
    if len(tables) != 2:
        raise ValueError('unexpected original song tables')
    pairs = []
    for row in tables[0].findall('TR'):
        cells = [' '.join(''.join(cell.itertext()).split()) for cell in row.findall('TD')]
        cells = [cell for cell in cells if cell]
        if len(cells) != 4 or not cells[1].isdigit() or not cells[3].isdigit():
            raise ValueError('unexpected frequency row')
        pairs.extend(((cells[0], int(cells[1])), (cells[2], int(cells[3]))))
    words = []
    for row in tables[1].findall('TR'):
        cells = row.findall('TD')
        if len(cells) != 1:
            raise ValueError('unexpected lyric row')
        words.extend(' '.join(''.join(cells[0].itertext()).split()).upper().split())
    if len(pairs) != 8 or len(words) != 36 or sum(weight for _, weight in pairs) != 36:
        raise ValueError('unexpected original frequency or lyric count')
    if any(not name.isalpha() or not name.isupper() for name, _ in pairs) or any(not word.isalpha() or not word.isupper() for word in words):
        raise ValueError('unexpected symbol spelling')
    if {name for name, _ in pairs} != set(words):
        raise ValueError('lyrics and frequency alphabets differ')
    return setup + '\n' + generate + '\n' + SOLUTION, pairs, words


def cases():
    setup, pairs, words = original_data()
    pair_expr = "'(" + ' '.join(f'({name} {weight})' for name, weight in pairs) + ')'
    lyric = "'(" + ' '.join(words) + ')'
    tree = f'(generate-huffman-tree {pair_expr})'
    samples = [
        ('2.69', "(weight (generate-huffman-tree '((A 4) (B 2) (D 1) (C 1))))", '8'),
        ('2.69', "(let ((tree (generate-huffman-tree '((A 4) (B 2) (D 1) (C 1))))) (decode (encode '(A B C D) tree) tree))", '(A B C D)'),
        ('2.70', f'(length {lyric})', '36'),
        ('2.70', f'(weight {tree})', '36'),
        ('2.70', f"(let ((tree {tree})) (length (encode '(GET A JOB) tree)))", '14'),
        ('2.70', f'(let ((tree {tree})) (length (encode {lyric} tree)))', '84'),
        ('2.70', f'(let ((tree {tree})) (equal? (decode (encode {lyric} tree) tree) {lyric}))', '#t'),
    ]
    return [dict(exercise=exercise, setup=setup, expression=source,
                 expected=expected, sequential_setup=True)
            for exercise, source, expected in samples]


def run(zig, chibi):
    result = runner.run(zig, chibi, case_builder=cases, source_verifier=lambda: None)
    result['note'] = ('Original MIT generator, XML song and frequencies; independently supplied '
                      'successive-merge and encode-symbol. Errors are observations, not matches.')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--zig', type=Path, required=True)
    parser.add_argument('--chibi', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(run(args.zig, args.chibi), indent=2))
