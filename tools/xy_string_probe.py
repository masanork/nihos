#!/usr/bin/env python3
"""Compare finite bounded string examples with pinned Chibi Scheme."""
import argparse
import json
from pathlib import Path
import sicp_abstraction_2_2_2_14 as runner


def cases():
    samples = [
        ('(string-length "")', '0'),
        ('(string-length "a日本😀é")', '6'),
        ('(string-append)', '""'),
        ('(string-append "a" "日本" "😀")', '"a日本😀"'),
        ('(string=? "日本" "日本" "日本")', '#t'),
        ('(string=? "é" "é")', '#f'),
        ('(string=? "x" "y" "x")', '#f'),
        ('(string-length (string-append "abc" "def"))', '6'),
    ]
    return [dict(exercise='bounded-strings', setup='', expression=source, expected=expected)
            for source, expected in samples]


def run(zig, chibi):
    # The shared runner emits a Zig string literal using json.dumps. Raw UTF-8
    # is legal in both formats; JSON's default \\uXXXX escapes are not Zig syntax.
    dumps = runner.json.dumps
    try:
        runner.json.dumps = lambda value, **kw: dumps(value, ensure_ascii=False, **kw)
        result = runner.run(zig, chibi, case_builder=cases, source_verifier=lambda: None)
    finally:
        runner.json.dumps = dumps
    result['note'] = 'Finite string examples; not R7RS string conformance.'
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--zig', type=Path, required=True)
    parser.add_argument('--chibi', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(run(args.zig, args.chibi), ensure_ascii=False, indent=2))
