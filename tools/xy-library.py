#!/usr/bin/env python3
"""Build xy's offline reading pack from attributed, pinned source and prepared book.
Run node docs/book/scripts/prepare.mjs first. Normal app builds copy the checked-in pack.
"""
import hashlib
import html
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / 'third_party/xy-reading'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Aozora(HTMLParser):
    def __init__(self):
        super().__init__()
        self.active = False
        self.parts, self.rubies, self.chapters = [], [], []
        self.length = 0
        self.in_rt = self.in_rp = self.in_heading = False
        self.base_start = 0
        self.reading = ''
        self.heading = ''

    def append(self, text):
        self.parts.append(text)
        self.length += len(text.encode())

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == 'div' and a.get('class') == 'main_text':
            self.active = True
        if not self.active:
            return
        if tag == 'div' and a.get('class') == 'bibliographical_information':
            self.active = False
        elif tag == 'ruby':
            self.base_start = self.length
        elif tag == 'rt':
            self.in_rt = True
            self.reading = ''
        elif tag == 'rp':
            self.in_rp = True
        elif tag == 'br':
            self.append('\n')
        elif tag == 'h4':
            self.in_heading = True
            self.heading = ''
        elif tag == 'img':
            # Restore standard JIS X 0213 gaiji instead of making its alt text
            # into an unbreakable ruby base dozens of characters long.
            match = re.search(r'([12])-(\d{2})-(\d{2})', a.get('src', ''))
            if match:
                plane, row, cell = map(int, match.groups())
                raw = bytes([row+160, cell+160])
                if plane == 2: raw = b'\x8f'+raw
                self.append(raw.decode('euc_jis_2004'))
            else:
                self.append(a.get('alt', '［外字］'))

    def handle_endtag(self, tag):
        if not self.active:
            return
        if tag == 'rt':
            self.in_rt = False
            self.rubies.append({'start': self.base_start, 'end': self.length, 'text': self.reading})
        elif tag == 'rp':
            self.in_rp = False
        elif tag == 'h4':
            self.in_heading = False
            self.chapters.append({'title': self.heading.strip(), 'start': self.length})

    def handle_data(self, text):
        if not self.active:
            return
        if self.in_rt:
            self.reading += text
        elif self.in_heading:
            self.heading += text
        elif not self.in_rp:
            # Source formatting CR/LF is not a paragraph; <br> is.
            self.append(text.replace('\r', '').replace('\n', ''))


def sicp_text(path):
    root = ET.fromstring(path.read_text())
    blocks = []
    skip = {'INDEX', 'JAVASCRIPT', 'JAVASCRIPT_OUTPUT', 'JAVASCRIPTINLINE', 'LABEL', 'SECTIONCONTENT', 'WEB_ONLY', 'JAVASCRIPT_ONLY', 'SOLUTION', 'REQUIRES', 'EXPECTED', 'EXAMPLE'}
    def block(text):
        blocks.append(text.strip())
        return f' XYBLOCK{len(blocks)-1} '
    def math(text):
        text = re.sub(r'\\begin\{array\}\{[^}]*\}|\\end\{array\}', '', text)
        for a, b in [(r'\[', ''), (r'\]', ''), (r'\cdots', '…'), (r'\cdot', '·'), (r'\leftarrow', '←'), (r'\left', ''), (r'\right', ''), (r'\quad', ' '), ('&', ''), ('$', '')]:
            text = text.replace(a, b)
        text = re.sub(r'\\(?:textrm|mathrm)\{([^}]*)\}', r'\1', text)
        return re.sub(r'\s+', ' ', text).strip()
    def walk(node):
        if node.tag in skip:
            return ''
        if node.tag == 'SNIPPET':
            parts = [''.join(c.itertext()).strip() for c in node if c.tag in ('SCHEME', 'SCHEMEOUTPUT', 'SCHEME_OUTPUT')]
            return block('\n'.join(parts)) if parts else ''
        if node.tag == 'LATEX':
            return block(math(''.join(node.itertext())))
        if node.tag == 'LATEXINLINE':
            return math(''.join(node.itertext()))
        if node.tag == 'REF':
            return '[' + node.attrib.get('NAME', '').removeprefix('sec:').removeprefix('fig:') + ']'
        if node.tag == 'APOS':
            return "'"
        if node.tag == 'EMDASH':
            return '—'
        if node.tag == 'SPACE':
            return ' '
        if node.tag == 'SOFT_HYP':
            return ''
        text = (node.text or '') + ''.join(walk(c) + (c.tail or '') for c in node)
        if node.tag in ('TEXT', 'NAME', 'LI', 'FOOTNOTE', 'FIGURE'):
            text = re.sub(r'\s+', ' ', text).strip() + '\n\n'
        return text
    text = walk(root)
    text = re.sub(r'&subsection[\d.]+;', '', text)
    text = re.sub(r'\n[ \t]+', '\n', text)
    text = re.sub(r'\n{3,}', '\n\n', text)
    # Nested blocks are resolved in reverse order to preserve code indentation.
    for i in reversed(range(len(blocks))):
        text = text.replace(f'XYBLOCK{i}', '\n\n' + blocks[i] + '\n\n')
    return re.sub(r'\n{3,}', '\n\n', text).strip() + '\n'


def markdown_text(text):
    # Prepared manuscript contains resolved snippets, source notes and cross-references.
    lines, code = [], False
    for line in text.splitlines():
        if line.startswith('```'):
            code = not code
            lines.append('')
            continue
        if not code:
            line = re.sub(r'<img\b[^>]*alt="([^"]*)"[^>]*>', r'図の説明：\1', line)
            line = re.sub(r'<[^>]+>', '', line)
            line = re.sub(r'^#{1,6}\s+', '', line)
            line = re.sub(r'!?\[([^\]]+)\]\([^)]*\)', r'\1', line)
            line = line.replace('**', '').replace('`', '')
            line = html.unescape(line)
        lines.append(line)
    return re.sub(r'\n{3,}', '\n\n', '\n'.join(lines)).strip() + '\n'


def section(title, text, rubies=None):
    return {'title': title, 'text': text, 'ruby': rubies or []}


def build():
    sources = json.loads((VENDOR / 'sources.json').read_text())
    for name, meta in sources.items():
        if digest(VENDOR / name) != meta['sha256']:
            raise ValueError(f'Pinned source changed: {name}')
    ao = Aozora()
    ao.feed((VENDOR / 'kusamakura.html').read_bytes().decode('shift_jis'))
    body = ''.join(ao.parts).encode()
    chapters = []
    for i, ch in enumerate(ao.chapters):
        start = ch['start']
        end = ao.chapters[i + 1]['start'] if i + 1 < len(ao.chapters) else len(body)
        ruby = [{'start': r['start'] - start, 'end': r['end'] - start, 'text': r['text']}
                for r in ao.rubies if start <= r['start'] < r['end'] <= end]
        chapters.append(section(ch['title'], body[start:end].decode(), ruby))
    book = json.loads(subprocess.check_output(['node', '-e', "console.log(JSON.stringify(require('./docs/book/book.cjs')))"], cwd=ROOT))
    book_sections = []
    for entry in book['entries']:
        path = ROOT / 'docs/book/_build/ja' / (entry['id'] + '.md')
        if not path.is_file():
            if entry['id'] in ('toc', 'index'):
                continue
            raise FileNotFoundError(f'{path}: run node docs/book/scripts/prepare.mjs')
        prepared = path.read_text()
        chapter = section(entry['title'], markdown_text(prepared))
        chapter['figures'] = [
            {'file': name, 'description': html.unescape(description)}
            for name, description in re.findall(r'<img src="\.\./figures/([^"/]+\.svg)" alt="([^"]*)"', prepared)]
        book_sections.append(chapter)
    tutorial = [
        section('はじめの一歩', 'xyへようこそ\n\nホームの「新規ファイル」から文章を書き始めましょう。「ファイルを開く」でUTF-8の文章を読み込めます。保存は⌘Sです。\n\nホームへ戻っても編集中の文書は残ります。「編集中の文書に戻る」で続きを書けます。\n\nこの使い方や本は閲覧専用です。矢印キー・Space・画面下のボタンでページをめくれます。\n'),
        section('文字を整える', '自分に合った読み心地に\n\nホームの表示設定では、文字サイズ、縦書き・横書き、明朝・ゴシック、明るい紙面・暗い紙面を選べます。\n\n本を開いてからも上の「表示設定」で変更できます。設定を変えても、いま読んでいる箇所を起点に組み直します。\n\n草枕には青空文庫のルビを添えています。SICPは英語原文の抜粋です。コードを含む章には横書きがおすすめです。\n'),
        section('Schemeで道具を育てる', 'xyのしくみを編集する\n\n文書画面の「Source」でuser/init.scmを開きます。ソースを書いたら「Apply & Save」で定義を保存して反映します。「Run Command」から登録した名前を呼び出せます。\n\n(define (stamp)\n  (buffer/insert! "Hello, xy!"))\n\nこの定義を保存し、stampを実行すると文書に挿入されます。\n\nSICPの例すべてを実行できる処理系ではありません。リポジトリの書籍は「端末の本」から章を選んで読めます。\n')]
    items = [
        {'id': 'tutorial', 'title': 'xyを使ってみる', 'author': 'nihos project', 'detail': '書く・読む・道具を育てる、3つのレッスン', 'source': 'https://github.com/masanork/nihos', 'license': 'MIT', 'sections': tutorial},
        {'id': 'kusamakura', 'title': '草枕', 'author': '夏目漱石', 'detail': '青空文庫 / 全13章・ルビ付き', 'source': sources['kusamakura.html']['url'], 'license': '本文：日本で著作権保護期間満了。底本：夏目漱石全集3（ちくま文庫、筑摩書房、1987）。入力：柴田卓治、校正：伊藤時也。青空文庫、1999年公開・2011年修正。HTMLから本文・ルビを抽出、JIS指定の外字画像はUnicodeへ復元。', 'sections': chapters},
        {'id': 'sicp', 'title': 'SICP', 'author': 'Harold Abelson / Gerald Jay Sussman / Julie Sussman', 'detail': '英語原文 / プログラミングの要素・式・再帰の抜粋', 'source': 'https://sicp.sourceacademy.org/', 'license': 'CC BY-SA 4.0 · https://creativecommons.org/licenses/by-sa/4.0/ · Scheme側の本文を抽出し、XMLをプレーンテキストへ変換。', 'sections': [section(title, sicp_text(VENDOR / name)) for name, title in [('sicp-elements.xml', '1.1 The Elements of Programming'), ('sicp-expressions.xml', '1.1.1 Expressions'), ('sicp-recursion.xml', '1.2.1 Linear Recursion and Iteration')]]},
        {'id': 'nihos', 'title': book['title'], 'author': book['author'], 'detail': '端末の本 / ZigとRISC-Vで学ぶ、実機のしくみと設計判断', 'source': 'https://github.com/masanork/nihos/tree/main/docs/book', 'license': 'MIT · 本文・コード引用・図の説明を収録。図版ボタンから章のMermaid図を閲覧できます。', 'sections': book_sections}]
    tracked = subprocess.check_output(['git', 'ls-files', 'docs/book/ja', 'docs/book/book.cjs', 'docs/book/scripts', 'docs/book/figures'], cwd=ROOT, text=True).splitlines()
    hashes = {p: digest(ROOT / p) for p in tracked}
    result = {'version': 1, 'bookSourceHashes': hashes, 'externalSources': sources, 'items': items}
    out = ROOT / 'assets/xy/library.json'
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(f'{out}: {len(chapters)} 草枕 chapters, {len(book_sections)} nihos sections, {out.stat().st_size} bytes')


if __name__ == '__main__':
    build()
