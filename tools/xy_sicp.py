"""Compile pinned Scheme XML into attributed text and a separate learning catalogue.

Only REQUIRES forms prerequisite edges. EXAMPLE names an invocation, never a
dependency of its definition. No source, output, or EXPECTED string is executed.
"""
import hashlib
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SKIP = {'INDEX', 'JAVASCRIPT', 'JAVASCRIPT_OUTPUT', 'JAVASCRIPTINLINE',
        'JAVASCRIPT_ONLY', 'WEB_ONLY', 'SOLUTION', 'LABEL', 'SECTIONCONTENT'}
OUTPUT = {'SCHEMEOUTPUT', 'SCHEME_OUTPUT'}
TOKEN = re.compile(r'\ufdd0(\d+)\ufdd1')
INLINE = re.compile(r'\ufdd2(\d+)\ufdd3')


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def xml_text(node):
    return ''.join(node.itertext()).strip()


def prerequisites(targets, snippets):
    """Bounded build-time topological order; EXAMPLE is deliberately not followed."""
    ordered, active, done = [], set(), set()

    def visit(key):
        if key not in snippets:
            raise ValueError(f'Unresolved snippet: {key}')
        if key in active:
            raise ValueError(f'REQUIRES cycle: {key}')
        if key in done:
            return
        active.add(key)
        for dependency in snippets[key]['requires']:
            visit(dependency)
        active.remove(key)
        done.add(key)
        ordered.append(key)

    for target in targets:
        visit(target)
    return ordered


def math_text(text):
    text = re.sub(r'\\begin\{array\}\{[^}]*\}|\\end\{array\}', '', text)
    for old, new in [(r'\[', ''), (r'\]', ''), (r'\cdots', '…'), (r'\cdot', '·'),
                     (r'\leftarrow', '←'), (r'\left', ''), (r'\right', ''),
                     (r'\quad', ' '), ('&', ''), ('$', '')]:
        text = text.replace(old, new)
    text = re.sub(r'\\(?:textrm|mathrm)\{([^}]*)\}', r'\1', text)
    return re.sub(r'\s+', ' ', text).strip()


def candidates(root):
    """Choose Scheme before examining snippets, including hidden support forms."""
    found = []

    def walk(node):
        if node.tag in SKIP:
            return
        if node.tag == 'SNIPPET':
            codes = node.findall('SCHEME')
            if len(codes) > 1:
                raise ValueError('Ambiguous multiple SCHEME bodies in SNIPPET')
            if codes:
                found.append(node)
            return
        for child in node:
            walk(child)

    walk(root)
    return found


def render(root, selected):
    """Project typed blocks to text, recording byte ranges during final emission."""
    atoms = []
    inlines = []

    def atom(kind, text, snippet=None):
        index = len(atoms)
        atoms.append((kind, text, snippet))
        return f' \ufdd0{index}\ufdd1 '

    def walk(node):
        if node.tag in SKIP or node.tag in {'REQUIRES', 'EXPECTED', 'EXAMPLE'}:
            return ''
        if node.tag == 'SNIPPET':
            if node.get('HIDE') == 'yes':
                return ''
            record = selected.get(node)
            parts = []
            if record:
                parts.append(atom('code', record['code'], record['id']))
            for child in node:
                if child.tag in OUTPUT:
                    parts.append(atom('reference_output', xml_text(child), record['id'] if record else None))
            return ''.join(parts)
        if node.tag == 'SCHEMEINLINE':
            index = len(inlines)
            inlines.append(''.join(node.itertext()))
            return f'\ufdd2{index}\ufdd3'
        if node.tag == 'LATEX':
            return atom('math', math_text(''.join(node.itertext())))
        if node.tag == 'LATEXINLINE':
            return math_text(''.join(node.itertext()))
        if node.tag == 'REF':
            return '[' + node.get('NAME', '').removeprefix('sec:').removeprefix('fig:') + ']'
        if node.tag in {'APOS', 'EMDASH', 'SPACE', 'SOFT_HYP'}:
            return {'APOS': "'", 'EMDASH': '—', 'SPACE': ' ', 'SOFT_HYP': ''}[node.tag]
        text = (node.text or '') + ''.join(walk(child) + (child.tail or '') for child in node)
        if node.tag in {'TEXT', 'NAME', 'LI', 'FOOTNOTE', 'FIGURE'}:
            text = re.sub(r'\s+', ' ', text).strip() + '\n\n'
        return text

    template = walk(root)
    template = re.sub(r'&subsection[\d.]+;', '', template)
    template = re.sub(r'\n[ \t]+', '\n', template)
    segments = []

    def prose(text):
        if segments and segments[-1][0] == 'prose':
            segments[-1] = ('prose', segments[-1][1] + text, None)
        else:
            segments.append(('prose', text, None))

    start = 0
    for match in TOKEN.finditer(template):
        prose(template[start:match.start()] + '\n\n')
        segments.append(atoms[int(match[1])])
        prose('\n\n')
        start = match.end()
    prose(template[start:])
    # Normalize prose before measuring offsets; never rewrite code or final text.
    segments = [(kind, re.sub(r'\n{3,}', '\n\n', text) if kind == 'prose' else text, sid)
                for kind, text, sid in segments]
    if segments:
        kind, text, sid = segments[0]
        segments[0] = (kind, text.lstrip() if kind == 'prose' else text, sid)
        kind, text, sid = segments[-1]
        segments[-1] = (kind, text.rstrip() if kind == 'prose' else text, sid)
    body, blocks, offset = [], [], 0
    for kind, text, sid in segments:
        if not text:
            continue
        if kind == 'prose':
            pieces, cursor, local = [], 0, 0
            for match in INLINE.finditer(text):
                prefix = text[cursor:match.start()]
                pieces.append(prefix); local += len(prefix.encode())
                code = inlines[int(match[1])]
                if code:
                    blocks.append({'kind':'inline_code','start':offset+local,'end':offset+local+len(code.encode())})
                pieces.append(code); local += len(code.encode()); cursor = match.end()
            pieces.append(text[cursor:]); text = ''.join(pieces)
        end = offset + len(text.encode())
        if kind != 'prose':
            block = {'kind': kind, 'start': offset, 'end': end}
            if sid:
                block['snippet'] = sid
            blocks.append(block)
        body.append(text)
        offset = end
    return ''.join(body) + '\n', blocks


def compile_book(vendor=None, manifest_path=None):
    vendor = Path(vendor or ROOT / 'third_party/xy-reading')
    manifest_path = Path(manifest_path or vendor / 'sicp-experiments.json')
    manifest_bytes = manifest_path.read_bytes()
    manifest = json.loads(manifest_bytes)
    if manifest.get('version') != 1:
        raise ValueError('Unsupported SICP manifest version')
    pins = json.loads((vendor / 'sources.json').read_text())
    snippets, sections, upstream, documents = {}, [], {}, []
    for section in manifest['sections']:
        filename = section['file']
        if Path(filename).name != filename:
            raise ValueError('Source must be a basename')
        source = (vendor / filename).read_bytes()
        digest = sha256(source)
        if digest != section['sha256'] or digest != pins[filename]['sha256']:
            raise ValueError(f'Pinned source changed: {filename}')
        if any(c in source.decode() for c in '\ufdd0\ufdd1\ufdd2\ufdd3'):
            raise ValueError('Reserved renderer marker in source')
        root = ET.fromstring(source)
        remaining = candidates(root)
        selected = {}
        for entry in section['snippets']:
            key, selector = entry['id'], entry['selector']
            if key in snippets or entry['kind'] not in {'expression', 'definition', 'display'}:
                raise ValueError(f'Duplicate ID or invalid kind: {key}')
            if set(selector) == {'name'}:
                matches = [n for n in remaining if n.findtext('NAME') == selector['name']]
            elif set(selector) == {'code_sha256'}:
                matches = [n for n in remaining if sha256(xml_text(n.find('SCHEME')).encode()) == selector['code_sha256']]
            else:
                raise ValueError(f'Invalid selector: {key}')
            if len(matches) != 1:
                raise ValueError(f'Missing or ambiguous source selector: {key}')
            node = matches[0]
            remaining.remove(node)
            name = node.findtext('NAME')
            if name:
                if name in upstream:
                    raise ValueError(f'Ambiguous upstream NAME: {name}')
                upstream[name] = key
            record = {
                'id': key, 'section': section['id'], 'kind': entry['kind'],
                'code': xml_text(node.find('SCHEME')),
                'reference_output': '\n'.join(xml_text(c) for c in node if c.tag in OUTPUT),
                'upstream_expected': node.findtext('EXPECTED'), 'upstream_name': name,
                'requires': [n.text.strip() for n in node.findall('REQUIRES')],
                'example': node.findtext('EXAMPLE'), 'features': entry['features'],
                'hidden': node.get('HIDE') == 'yes',
                'eval_disabled': node.get('EVAL') == 'no' or entry['kind'] == 'display',
                'source': {'file': filename, 'sha256': digest, 'url': pins[filename]['url'],
                           'selector': selector},
            }
            snippets[key] = selected[node] = record
        if remaining:
            raise ValueError(f'Unclassified Scheme snippets in {filename}: {len(remaining)}')
        documents.append((root, selected, section))
    for record in snippets.values():
        try:
            record['requires'] = [upstream[name] for name in record['requires']]
            record['example'] = upstream[record['example']] if record['example'] else None
        except KeyError as error:
            raise ValueError(f'Unresolved upstream reference: {error}') from error
    for record in snippets.values():
        prerequisites([record['id']], snippets)
    source_order = []
    for root, selected, section in documents:
        text, blocks = render(root, selected)
        sections.append({'id': section['id'], 'title': section['title'], 'text': text,
                         'ruby': [], 'text_sha256': sha256(text.encode()), 'blocks': blocks})
        source_order.extend(selected[node] for node in candidates(root))
    if len({s['id'] for s in sections}) != len(sections):
        raise ValueError('Duplicate section ID')
    experiments = []
    for record in source_order:
        if record['hidden'] or record['eval_disabled']:
            continue
        probe = record['example'] or record['id']
        order = prerequisites([record['id'], probe], snippets)
        if any(snippets[key]['eval_disabled'] for key in order):
            raise ValueError(f'Experiment depends on display-only code: {record["id"]}')
        expected_owner = record if record['upstream_expected'] is not None else snippets[probe]
        reference = None
        if expected_owner['upstream_expected'] is not None:
            reference = {'kind': 'upstream_expected', 'snippet': expected_owner['id'],
                         'text': expected_owner['upstream_expected'], 'approved': False}
        elif record['reference_output']:
            reference = {'kind': 'reference_output', 'snippet': record['id'],
                         'text': record['reference_output'], 'approved': False}
        experiments.append({'id': record['id'] + '.try', 'editable': record['id'],
                            'invocation': probe, 'run_order': order, 'reference': reference,
                            'features': sorted({f for key in order for f in snippets[key]['features']}),
                            'execution_status': 'unqualified'})
    return {'version': 1, 'book_id': manifest['book_id'], 'edition': manifest['edition'],
            'manifest_sha256': sha256(manifest_bytes),
            'author': 'Harold Abelson and Gerald Jay Sussman with Julie Sussman',
            'license': 'CC-BY-SA-4.0', 'license_url': 'https://creativecommons.org/licenses/by-sa/4.0/',
            'source': 'https://sicp.sourceacademy.org/',
            'changes': 'Scheme text extracted; code and output separated; hidden support retained in catalogue; math converted to text.',
            'sections': sections, 'snippets': source_order, 'experiments': experiments}


def learning_asset(compiled, library_bytes):
    result = {key: value for key, value in compiled.items() if key != 'sections'}
    result['library_sha256'] = sha256(library_bytes)
    result['sections'] = [{key: value for key, value in section.items() if key not in {'text', 'ruby'}}
                          for section in compiled['sections']]
    return result


def validate_asset(asset, library_bytes):
    """Reject stale assets and verify every published byte range against its source code."""
    if asset['library_sha256'] != sha256(library_bytes):
        raise ValueError('Learning/reading library identity mismatch')
    library = json.loads(library_bytes)
    book = next(item for item in library['items'] if item['id'] == asset['book_id'])
    sections = {section['id']: section for section in book['sections']}
    snippets = {snippet['id']: snippet for snippet in asset['snippets']}
    if len(snippets) != len(asset['snippets']):
        raise ValueError('Duplicate snippet ID')
    for section in asset['sections']:
        body = sections[section['id']]['text'].encode()
        if sha256(body) != section['text_sha256']:
            raise ValueError('Section identity mismatch')
        previous = 0
        for block in section['blocks']:
            start, end = block['start'], block['end']
            if not 0 <= previous <= start < end <= len(body):
                raise ValueError('Invalid block range')
            body[:start].decode(); body[start:end].decode()
            if block['kind'] == 'code':
                snippet = snippets[block['snippet']]
                if snippet['section'] != section['id'] or body[start:end].decode() != snippet['code']:
                    raise ValueError('Code range mismatch')
            previous = end
    for snippet in snippets.values():
        prerequisites([snippet['id']], snippets)
    for experiment in asset['experiments']:
        order = prerequisites([experiment['editable'], experiment['invocation']], snippets)
        if experiment['run_order'] != order:
            raise ValueError('Invalid experiment run order')


def write_assets(library, compiled, library_path, learning_path, check=False):
    library['learningPacks'] = [{'book': compiled['book_id'], 'path': learning_path.name, 'version': 1}]
    encoded = (json.dumps(library, ensure_ascii=False, indent=2) + '\n').encode()
    asset = learning_asset(compiled, encoded)
    validate_asset(asset, encoded)
    metadata = (json.dumps(asset, ensure_ascii=False, indent=2) + '\n').encode()
    for path, content in ((library_path, encoded), (learning_path, metadata)):
        if check:
            if not path.is_file() or path.read_bytes() != content:
                raise ValueError(f'Stale generated asset: {path}')
        else:
            path.write_bytes(content)
    return asset


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    compiled = compile_book()
    library_path = ROOT / 'assets/xy/library.json'
    learning_path = ROOT / 'assets/xy/sicp-learning.json'
    library = json.loads(library_path.read_bytes())
    item = next(item for item in library['items'] if item['id'] == compiled['book_id'])
    item['sections'] = [{k: section[k] for k in ('id', 'title', 'text', 'ruby')}
                        for section in compiled['sections']]
    asset = write_assets(library, compiled, library_path, learning_path, args.check)
    print(f"SICP: {len(asset['snippets'])} snippets, {len(asset['experiments'])} experiments")
