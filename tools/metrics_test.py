#!/usr/bin/env python3
"""Regression checks for scope, test splitting, and source-bound coverage."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import metrics


class MetricsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)

    def put(self, path, text):
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)
        return file

    def test_zig_braces_in_comments_strings_chars_and_multiline_strings(self):
        text = ('const a = "test {";\n'
                'test "name }" {\n'
                '    const a = "}"; // {\n'
                "    const b = '}';\n"
                '    const c =\n'
                '        \\\\ } {\n'
                '    ;\n'
                '    if (true) { _ = a; _ = b; _ = c; }\n'
                '}\n'
                'pub fn implementation() void {}\n'
                'test { }\n')
        self.assertEqual(metrics.zig_test_lines(text), set(range(2, 10)) | {11})

    def test_inventory_deduplicates_tracked_modified_files_and_ignores_caches(self):
        self.put('.gitignore', 'build/\nmanaged_components/\n')
        self.put('src/a.zig', 'pub fn a() void {}\ntest "a" {}\n')
        subprocess.run(['git', '-C', str(self.root), 'add', '.'], check=True)
        self.put('src/a.zig', 'pub fn a() void {}\ntest "a" {}\n// changed\n')
        self.put('src/extra_test.zig', '// test helper\ntest {}\n')
        self.put('src/graphics/test_pattern.zig', 'pub fn paint() void {}\ntest {}\n')
        self.put('build/unused.c', 'ignored\n' * 100)
        self.put('managed_components/sdk/a.c', 'ignored\n' * 100)
        self.put('docs/book/a.py', 'excluded\n')
        self.put('probes/language/c/probe.c', 'probe\n')
        files = metrics.inventory(self.root, 'nihos')
        self.assertEqual(len(files), 4)
        self.assertEqual(sum(f['lines']['implementation'] for f in files), 3)
        self.assertEqual(sum(f['lines']['tests'] for f in files), 4)
        self.assertEqual(sum(f['lines']['probes'] for f in files), 1)

    def test_meos_vendor_data_and_tooling_are_separate(self):
        for path in ['third_party/doomgeneric/info.c', 'drivers/lcd/font_ja16.c',
                     'drivers/lcd/display.c', 'tools/sim/build.sh', 'tools/sd/fat_test.c']:
            self.put(path, '// line\n')
        files = metrics.inventory(self.root, 'meos')
        self.assertEqual(sorted(next(k for k, v in f['lines'].items() if v) for f in files),
                         ['generated', 'implementation', 'tests', 'tooling', 'vendored'])

    def test_cobertura_deduplicates_lines_and_excludes_test_code(self):
        self.put('src/a.zig', 'pub fn a() void {\n    return;\n}\ntest {}\n')
        self.put('src/a_test.zig', 'test {}\n')
        self.put('src/uncompiled.zig', 'pub fn unused() void {}\n')
        xml = self.put('coverage.xml', '''<coverage><sources><source>/work/src/</source></sources><packages><package><classes>
<class filename="a.zig"><lines>
<line number="1" hits="1"/><line number="2" hits="0"/><line number="4" hits="1"/>
</lines></class>
<class filename="src/a.zig"><lines><line number="1" hits="0"/></lines></class>
<class filename="src/a_test.zig"><lines><line number="1" hits="1"/></lines></class>
<class filename="/sdk/std.zig"><lines><line number="1" hits="1"/></lines></class>
</classes></package></packages></coverage>''')
        report = metrics.parse_cobertura(self.root, xml, Path('/work'))
        self.assertEqual(report['lines'], {'covered': 1, 'count': 2, 'percent': 50.0})
        self.assertIn('src/uncompiled.zig', report['unrepresentedSourceFiles'])
        saved = self.put('coverage.json', json.dumps(report))
        self.assertEqual(metrics.coverage(self.root, saved), report)
        self.put('src/a.zig', '// changed source\n')
        with self.assertRaisesRegex(ValueError, 'source hashes'):
            metrics.coverage(self.root, saved)

    def test_missing_coverage_is_a_gap_in_chart(self):
        point = {'date': '2026-10-25', 'coverage': None, 'code': {}}
        svg = metrics.chart([point], coverage_chart=True)
        self.assertIn('Coverage unavailable', svg)
        self.assertNotIn('<title>', svg)


if __name__ == '__main__':
    unittest.main()
