#!/usr/bin/env python3
"""Dependency-free physical-line tracker for nihos and a read-only MeOS checkout."""
import argparse
from collections import defaultdict
from datetime import datetime, timezone
import hashlib
from html import escape
import json
import os
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
SCHEMA = 1
LANGUAGES = {'.zig': 'Zig', '.c': 'C', '.h': 'C/header', '.s': 'Assembly',
             '.inc': 'Include/data', '.rs': 'Rust', '.py': 'Python', '.sh': 'Shell'}
PRODUCT_ROOTS = {
    'nihos': {'src', 'compat', 'include', 'main'},
    'meos': {'kernel', 'hal', 'drivers', 'fs', 'user', 'apps', 'main', 'components'},
}
BUCKETS = ('implementation', 'tests', 'tooling', 'probes', 'vendored', 'generated')
# Treat these entire mixed data/decoder files as data; do not pretend to split C semantics.
MEOS_DATA = {'drivers/lcd/font_ja16.c', 'drivers/lcd/font8x8.c',
             'drivers/lcd/bizud24_data.inc', 'drivers/ime/ime_mini_dict.c',
             'apps/m5ex/images.c', 'apps/wasm/wasm_images.c'}


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args])


def candidates(root):
    # Include current local work, but never ignored SDK/build/download caches.
    return sorted(set(os.fsdecode(p) for p in git(
        root, 'ls-files', '-z', '-c', '-o', '--exclude-standard').split(b'\0') if p))


def zig_test_lines(text):
    """1-based test-block lines; mask comments, strings, chars and multiline strings."""
    token = r'//[^\n]*|"(?:\\.|[^"\\\n])*"|\x27(?:\\.|[^\x27\\\n])*\x27|^[ \t]*\\\\[^\n]*'
    masked = re.sub(token, lambda m: ' ' * len(m[0]), text, flags=re.MULTILINE)
    result = set()
    active = False
    opened = False
    depth = 0
    for number, line in enumerate(masked.splitlines(), 1):
        if not active and re.match(r'^\s*test\b', line):
            active = True
        if active:
            result.add(number)
            opened = opened or '{' in line
            depth += line.count('{') - line.count('}')
            if opened and depth == 0:
                active = opened = False
    if active:
        raise ValueError('Unterminated Zig test block')
    return result


def is_test(path):
    # A production display-pattern renderer, with its own inline unit tests.
    if path == 'src/graphics/test_pattern.zig':
        return False
    p = Path(path)
    return (bool({'test', 'tests'} & set(p.parts)) or
            bool(re.search(r'(^test[_.-]|[_.-]test(?:[_.-]|$)|[_.-]spec\.)', p.name)) or
            path == 'apps/m5ex/m5test.c')


def category(profile, path):
    p = Path(path)
    if p.suffix.lower() not in LANGUAGES:
        return None
    first = p.parts[0]
    if first == 'third_party':
        return 'vendored'
    if profile == 'meos' and path in MEOS_DATA:
        return 'generated'
    if first == 'probes':
        return 'probes'
    if first not in PRODUCT_ROOTS[profile] | {'tools'} and path != 'build.zig':
        return None
    if is_test(path):
        return 'tests'
    return 'tooling' if first == 'tools' or path == 'build.zig' else 'implementation'


def inventory(root, profile):
    files = []
    for path in candidates(root):
        bucket = category(profile, path)
        full = root / path
        if bucket is None or not full.is_file() or full.is_symlink():
            continue
        data = full.read_bytes()
        text = data.decode('utf-8')
        total = len(text.splitlines())
        tests = zig_test_lines(text) if path.endswith('.zig') else set()
        counts = {k: 0 for k in BUCKETS}
        counts[bucket] = total
        if bucket == 'implementation':
            counts['implementation'] -= len(tests)
            counts['tests'] += len(tests)
        files.append({'path': path, 'language': LANGUAGES[full.suffix.lower()],
                      'sha256': hashlib.sha256(data).hexdigest(), 'lines': counts})
    return files


def source_hashes(root):
    return {f['path']: f['sha256'] for f in inventory(root, 'nihos')
            if f['path'].startswith('src/')}


def coverage(root, path):
    if path is None:
        return None
    report = json.loads(path.read_text())
    if report['sourceHashes'] != source_hashes(root):
        raise ValueError('Coverage source hashes do not match the measured src/ tree')
    if report['scope'] != 'host-zig-debug-dwarf-implementation':
        raise ValueError('Unsupported coverage scope')
    return report


def parse_cobertura(root, xml_path, build_root):
    """Count only emitted implementation lines; omit all test files/inline blocks."""
    hashes = source_hashes(root)
    lines = {}
    document = ET.parse(xml_path)
    sources = [Path(item.text) for item in document.iter('source') if item.text]
    for cls in document.iter('class'):
        filename = Path(cls.attrib['filename'])
        options = [filename] if filename.is_absolute() else [filename] + [
            source / filename for source in sources]
        path = None
        for option in options:
            try:
                relative = option.relative_to(build_root) if option.is_absolute() else option
            except ValueError:
                continue
            if relative.as_posix() in hashes:
                path = relative.as_posix()
                break
        if path is None or is_test(path):
            continue
        text = (root / path).read_text()
        tests = zig_test_lines(text)
        total_lines = len(text.splitlines())
        for item in cls.iter('line'):
            number, hits = int(item.attrib['number']), int(item.attrib['hits'])
            if number < 1 or number > total_lines or hits < 0:
                raise ValueError('Invalid coverage line')
            if number not in tests:
                lines[path, number] = max(lines.get((path, number), 0), hits)
    if not lines:
        raise ValueError('No implementation lines found in coverage report')
    by_file = {}
    for path in sorted({p for p, _ in lines}):
        hits = [v for (p, _), v in lines.items() if p == path]
        by_file[path] = {'covered': sum(v > 0 for v in hits), 'count': len(hits)}
    count = len(lines)
    covered = sum(v > 0 for v in lines.values())
    return {'scope': 'host-zig-debug-dwarf-implementation', 'collector': 'kcov v43',
            'sourceHashes': hashes, 'lines': {'covered': covered, 'count': count,
                                             'percent': covered * 100 / count},
            'files': by_file,
            'unrepresentedSourceFiles': sorted(set(hashes) - set(by_file))}


def snapshot(root, profile, coverage_path=None):
    files = inventory(root, profile)
    totals = {k: sum(f['lines'][k] for f in files) for k in BUCKETS}
    by_language = defaultdict(lambda: {k: 0 for k in BUCKETS})
    by_area = defaultdict(lambda: {k: 0 for k in BUCKETS})
    for f in files:
        for bucket in BUCKETS:
            by_language[f['language']][bucket] += f['lines'][bucket]
            by_area[f['path'].split('/')[0]][bucket] += f['lines'][bucket]
    fingerprint = '\n'.join(f"{f['path']}\0{f['sha256']}" for f in files)
    return {'schemaVersion': SCHEMA, 'date': datetime.now(timezone.utc).date().isoformat(),
            'measuredAt': datetime.now(timezone.utc).isoformat(), 'project': profile,
            'commit': git(root, 'rev-parse', 'HEAD').decode().strip(),
            'workingTreeDirty': bool(git(root, 'status', '--porcelain', '--untracked-files=normal')),
            'sourceTreeSha256': hashlib.sha256(fingerprint.encode()).hexdigest(),
            'code': totals, 'byLanguage': dict(by_language), 'byArea': dict(by_area),
            'coverage': coverage(root, coverage_path), 'files': files}


def markdown(current, other=None):
    rows = [current] + ([other] if other else [])
    out = ['# Project metrics', '',
           '| Physical source lines | ' + ' | '.join(r['project'] for r in rows) + ' |',
           '|---|' + '---:|' * len(rows)]
    for bucket in BUCKETS:
        out.append('| ' + bucket + ' | ' + ' | '.join(f"{r['code'][bucket]:,}" for r in rows) + ' |')
    out += ['', 'Physical lines include comments and blanks. Test-code volume is not execution coverage.', '']
    for r in rows:
        out += [f"## {r['project']}", '',
                f"Commit: `{r['commit']}`; working tree dirty: `{r['workingTreeDirty']}`; UTC: {r['measuredAt']}.",
                f"Measured source fingerprint: `{r['sourceTreeSha256']}`.", '',
                '| Area | Implementation | Tests | Tooling |', '|---|---:|---:|---:|']
        for area, values in sorted(r['byArea'].items()):
            out.append(f"| {area} | {values['implementation']:,} | {values['tests']:,} | {values['tooling']:,} |")
        cov = r['coverage']
        if cov:
            c = cov['lines']
            out += ['', f"Host Zig emitted implementation line coverage: **{c['percent']:.1f}% ({c['covered']}/{c['count']})**.",
                    f"{len(cov['files'])} files represented; {len(cov['unrepresentedSourceFiles'])} src/ files unrepresented.",
                    'Only DWARF lines emitted in the Debug host test binary are in the denominator.',
                    'Uncompiled functions/files, C/assembly, emulator and physical-device execution are outside this percentage.']
        else:
            out += ['', 'Execution coverage: **unavailable** (not zero).']
        out.append('')
    return '\n'.join(out)


def chart(history, coverage_chart=False):
    title = 'Host Zig emitted-line coverage' if coverage_chart else 'nihos source growth'
    subtitle = ('Debug DWARF implementation lines only; missing measurements are gaps' if coverage_chart
                else 'Physical lines incl. comments/blanks; dependencies and generated data excluded')
    series = [('coverage', '#2563eb')] if coverage_chart else [
        ('implementation', '#2563eb'), ('tests', '#10b981'), ('tooling', '#f59e0b')]
    width, height, left, top, bottom = 820, 340, 65, 78, 262
    maximum = 100 if coverage_chart else max(1, max(
        sum(r['code'][key] for key, _ in series) for r in history)) * 1.1
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
           '<rect width="100%" height="100%" fill="white"/>',
           '<g font-family="system-ui,sans-serif" fill="#344054">',
           f'<text x="{left}" y="30" font-size="20">{title}</text>',
           f'<text x="{left}" y="53" font-size="12">{escape(subtitle)}</text>']
    for i in range(5):
        value = maximum * i / 4
        y = bottom - (bottom - top) * i / 4
        svg += [f'<path d="M{left} {y}H790" stroke="#eaecf0"/>',
                f'<text x="55" y="{y + 4}" text-anchor="end" font-size="11">{value:,.0f}</text>']
    bar_width = min(55, 650 / max(1, len(history)))
    any_coverage = False
    for i, row in enumerate(history):
        x = left + 45 + i * 640 / max(1, len(history) - 1)
        cumulative = 0
        for key, color in series:
            if coverage_chart:
                if row['coverage'] is None:
                    continue
                any_coverage = True
                value = row['coverage']['lines']['percent']
            else:
                value = row['code'][key]
            h = value / maximum * (bottom - top)
            y = bottom - cumulative - h
            svg.append(f'<rect x="{x - bar_width / 2}" y="{y}" width="{bar_width}" height="{h}" fill="{color}"><title>{escape(row["date"])}: {key} {value:,.1f}</title></rect>')
            cumulative += h
        if i in {0, len(history) - 1}:
            svg.append(f'<text x="{x}" y="286" text-anchor="middle" font-size="11">{escape(row["date"])}</text>')
    if coverage_chart and not any_coverage:
        svg.append('<text x="300" y="170" font-size="18">Coverage unavailable</text>')
    for i, (key, color) in enumerate(series):
        x = left + i * 200
        svg += [f'<rect x="{x}" y="309" width="12" height="12" fill="{color}"/>',
                f'<text x="{x + 18}" y="320" font-size="12">{key}</text>']
    return '\n'.join(svg + ['</g></svg>', ''])


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=ROOT)
    parser.add_argument('--profile', choices=PRODUCT_ROOTS, default='nihos')
    parser.add_argument('--compare', type=Path, help='read-only MeOS working tree')
    parser.add_argument('--coverage', type=Path, help='source-bound host-coverage.json')
    parser.add_argument('--output-dir', type=Path, default=ROOT / 'build/metrics')
    parser.add_argument('--record', action='store_true')
    parser.add_argument('--snapshot-file', type=Path, help='record an existing CI snapshot')
    args = parser.parse_args()
    root, output = args.repo.resolve(), args.output_dir.resolve()
    if args.snapshot_file:
        current = json.loads(args.snapshot_file.read_text())
        if (current['schemaVersion'] != SCHEMA or current['project'] != args.profile or
                current['commit'] != git(root, 'rev-parse', 'HEAD').decode().strip()):
            raise ValueError('Snapshot does not match the checkout/schema/profile')
        fresh = snapshot(root, args.profile)
        if current['sourceTreeSha256'] != fresh['sourceTreeSha256']:
            raise ValueError('Snapshot source fingerprint does not match checkout')
    else:
        current = snapshot(root, args.profile, args.coverage)
    other = snapshot(args.compare.resolve(), 'meos') if args.compare else None
    history_path = root / 'metrics/history.json'
    history = json.loads(history_path.read_text()) if history_path.exists() else []
    # Keep history compact; detailed per-file provenance stays in the CI artifact.
    point = {k: v for k, v in current.items() if k != 'files'}
    history = sorted([r for r in history if r['date'] != point['date']] + [point],
                     key=lambda r: r['date'])
    output.mkdir(parents=True, exist_ok=True)
    write_json(output / 'current.json', current)
    if other:
        write_json(output / 'comparison.json', other)
    report = markdown(current, other)
    (output / 'summary.md').write_text(report)
    for name, is_coverage in [('code-size.svg', False), ('coverage.svg', True)]:
        (output / name).write_text(chart(history, is_coverage))
    if args.record:
        write_json(history_path, history)
        for name in ['code-size.svg', 'coverage.svg', 'summary.md']:
            (root / 'metrics' / name).write_text((output / name).read_text())
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
            summary.write(report)
    print(report)


if __name__ == '__main__':
    main()
