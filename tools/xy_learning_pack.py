"""Offset-only, read-only SICP learning catalogue (XYLAB001, version 2, styled spans)."""
import json
from pathlib import Path
import struct

from xy_sicp import compile_book, learning_asset, validate_asset

HEADER = 128
SECTION = 44
SNIPPET = 68
EXPERIMENT = 40
NONE = 0xffffffff


def load_asset(root):
    root = Path(root)
    library = (root / 'assets/xy/library.json').read_bytes()
    asset = json.loads((root / 'assets/xy/sicp-learning.json').read_bytes())
    compiled = compile_book(root / 'third_party/xy-reading')
    if asset != learning_asset(compiled, library):
        raise ValueError('Stale SICP learning asset; run python3 tools/xy_sicp.py')
    validate_asset(asset, library)
    return asset, json.loads(library)


def encode(asset, library):
    sections, snippets, experiments = asset['sections'], asset['snippets'], asset['experiments']
    section_ids = {s['id']: i for i, s in enumerate(sections)}
    snippet_ids = {s['id']: i for i, s in enumerate(snippets)}
    if not 0 < len(sections) <= 256 or not 0 < len(snippets) <= 4096 or len(experiments) > 4096:
        raise ValueError('Catalogue count exceeds format limits')
    def bounded(value, limit):
        if len((value or '').encode()) > limit:
            raise ValueError('Catalogue string exceeds format limit')
    for section in sections:
        bounded(section['id'], 128)
    for snippet in snippets:
        for field, limit in [('id', 128), ('code', 4096), ('reference_output', 4096),
                             ('upstream_expected', 1024), ('upstream_name', 128)]:
            bounded(snippet[field], limit)
    for experiment in experiments:
        bounded(experiment['id'], 128)
        bounded(experiment['reference']['text'] if experiment['reference'] else '', 4096)
        bounded('\n'.join(experiment['features']), 1024)
    text = {s['id']: s['text'] for item in library['items'] if item['id'] == asset['book_id']
            for s in item['sections']}
    anchors = {b['snippet']: (b['start'], b['end']) for s in sections
               for b in s['blocks'] if b['kind'] == 'code'}
    section_at = HEADER
    snippet_at = section_at + SECTION * len(sections)
    experiment_at = snippet_at + SNIPPET * len(snippets)
    refs_at = experiment_at + EXPERIMENT * len(experiments)
    refs = []

    def reference(keys):
        start = len(refs)
        refs.extend(snippet_ids[key] for key in keys)
        return start, len(keys)

    requires = [reference(s['requires']) for s in snippets]
    plans = [reference(e['run_order']) for e in experiments]
    if len(refs) > 65536:
        raise ValueError('Catalogue references exceed format limit')
    styles = [(i,b['start'],b['end']) for i,section in enumerate(sections)
              for b in section['blocks'] if b['kind'] in ('code','reference_output','inline_code','math')]
    if len(styles)>65536: raise ValueError('Too many typography spans')
    styles_at = refs_at + 4 * len(refs)
    strings_at = styles_at + 12 * len(styles)
    data = bytearray(strings_at)
    strings = {}

    def put(value):
        encoded = (value or '').encode()
        if encoded not in strings:
            strings[encoded] = len(data), len(encoded)
            data.extend(encoded)
        return strings[encoded]

    credits = '\n'.join((asset['author'], 'Structure and Interpretation of Computer Programs, second edition',
                         asset['license'], asset['license_url'], asset['source'], asset['changes'])) + '\n'
    bounded(credits, 4096)
    credit_offset, credit_length = put(credits)
    for i, section in enumerate(sections):
        struct.pack_into('<3I32s', data, section_at + SECTION * i,
                         *put(section['id']), len(text[section['id']].encode()),
                         bytes.fromhex(section['text_sha256']))
    for i, snippet in enumerate(snippets):
        anchor = anchors.get(snippet['id'])
        flags = (1 if snippet['hidden'] else 0) | (2 if snippet['eval_disabled'] else 0)
        flags |= 4 if snippet['kind'] == 'definition' else 0
        flags |= 8 if anchor else 0
        fields = (*put(snippet['id']), section_ids[snippet['section']], *put(snippet['code']),
                  *put(snippet['reference_output']), *put(snippet['upstream_expected']),
                  *put(snippet['upstream_name']), *requires[i],
                  snippet_ids[snippet['example']] if snippet['example'] else NONE,
                  flags, *(anchor or (NONE, NONE)))
        struct.pack_into('<17I', data, snippet_at + SNIPPET * i, *fields)
    for i, experiment in enumerate(experiments):
        reference_text = experiment['reference']['text'] if experiment['reference'] else ''
        struct.pack_into('<10I', data, experiment_at + EXPERIMENT * i,
                         *put(experiment['id']), snippet_ids[experiment['editable']],
                         snippet_ids[experiment['invocation']], *plans[i],
                         *put(reference_text), *put('\n'.join(experiment['features'])))
    for i, ref in enumerate(refs):
        struct.pack_into('<I', data, refs_at + 4 * i, ref)
    for i,row in enumerate(styles): struct.pack_into('<3I',data,styles_at+12*i,*row)
    if len(data) > 16 * 1024 * 1024:
        raise ValueError('Catalogue exceeds format size limit')
    struct.pack_into('<8s14I32s32s', data, 0, b'XYLAB001', 2, len(data), len(sections),
                     len(snippets), len(experiments), len(styles), section_at, snippet_at, experiment_at,
                     refs_at, len(refs), strings_at, credit_offset, credit_length,
                     bytes.fromhex(asset['library_sha256']), bytes.fromhex(asset['manifest_sha256']))
    return bytes(data)


def build(root):
    asset, library = load_asset(root)
    return encode(asset, library)


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(build(Path(__file__).resolve().parents[1]))
