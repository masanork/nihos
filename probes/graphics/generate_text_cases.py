#!/usr/bin/env python3
"""One set of UTF-8 inputs for native options and independent host execution."""
import json
from pathlib import Path
import sys


def quoted(text):
    return '"' + ''.join(f'\\x{byte:02x}' for byte in text.encode()) + '"'


def generate(kind):
    cases = json.loads(Path(__file__).with_name("text_cases.json").read_text())
    assert len(cases) == 5
    rows = []
    for item in cases:
        assert 0 < len(item['body'].encode()) <= 128 and len(item['ruby'].encode()) <= 64
        assert item['font'] in (0, 1) and item['pixels'] in (12, 16, 24, 32)
        assert item['vertical'] in (0, 1) and item['hinting'] in (0, 1, 2)
        if kind == "zig":
            fields = ', '.join(f'.{key} = @as(u32, {item[key]})' for key in ('font', 'pixels', 'vertical', 'hinting'))
            rows.append('.{' + fields + ', .body = ' + quoted(item['body']) + ', .ruby = ' + quoted(item['ruby']) + '}')
        else:
            values = [str(item[k]) for k in ('font', 'pixels', 'vertical', 'hinting')]
            values += [str(len(item['body'].encode())), str(len(item['ruby'].encode())), quoted(item['body']), quoted(item['ruby'])]
            rows.append('{' + ','.join(values) + '}')
    if kind == "zig":
        return 'pub const font_text_cases = .{\n' + ',\n'.join(rows) + '\n};\n'
    return 'static const GraphicsRender text_cases[5] = {\n' + ',\n'.join(rows) + '\n};\n'


if __name__ == '__main__':
    if sys.argv[1] == '--zig':
        print(generate('zig'), end='')
    else:
        assert sys.argv[1] == '--header'
        Path(sys.argv[2]).write_text(generate('header'))
