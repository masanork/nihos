#!/usr/bin/env python3
"""Finite list quasiquote comparisons against pinned Chibi, not conformance."""
import argparse
import json
from pathlib import Path
import sicp_abstraction_2_2_2_14 as runner


def cases():
    samples = [
        ('`a', 'a'),
        ('`(a b c)', '(a b c)'),
        ('(let ((x 2)) `(1 ,x 3))', '(1 2 3)'),
        ('`(a ,(+ 1 2) ,@(list 4 5) . ,(+ 2 5))', '(a 3 4 5 . 7)'),
        ('(let ((x 2)) `(a `(b ,x ,,x) ,x))', '(a (quasiquote (b (unquote x) (unquote 2))) 2)'),
        ('`(a ,@(list) b)', '(a b)'),
        ('`(a unquote (+ 1 2))', '(a . 3)'),
        ("(let ((x '(9 8))) `(1 ,@x 3))", '(1 9 8 3)'),
        ('`(quasiquote (a (unquote (+ 1 2))))', '(quasiquote (a (unquote (+ 1 2))))'),
        ("(let ((x 'a)) `(list ,x ',x))", '(list a (quote a))'),
        ('`(0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25)',
         '(0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25)'),
    ]
    return [dict(exercise='list-quasiquote', setup='', expression=source, expected=answer)
            for source, answer in samples]


def run(zig, chibi):
    result = runner.run(zig, chibi, case_builder=cases, source_verifier=lambda: None)
    result['note'] = 'Finite list and pair examples only; vectors, macro hygiene, and full R7RS remain untested.'
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--zig', type=Path, required=True)
    parser.add_argument('--chibi', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(run(args.zig, args.chibi), indent=2))
