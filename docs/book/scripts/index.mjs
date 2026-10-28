import unified from 'unified';
import remarkParse from 'remark-parse';
import { createHash } from 'node:crypto';

const parser = unified().use(remarkParse);
const escapeHtml = value => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
const collator = new Intl.Collator('ja');

function occurrence(text, alias) {
  let offset = text.indexOf(alias);
  while (offset >= 0) {
    const word = character => character !== undefined && /[A-Za-z0-9_]/.test(character);
    if (!(word(alias[0]) && word(text[offset - 1])) &&
        !(word(alias.at(-1)) && word(text[offset + alias.length]))) return offset;
    offset = text.indexOf(alias, offset + 1);
  }
  return -1;
}

export class BookIndex {
  constructor(terms) {
    const ids = new Set();
    const anchors = new Set();
    this.terms = terms.map(term => {
      if (!/^[a-z0-9-]+$/.test(term.id) || ids.has(term.id) || !term.term || !term.reading ||
          !Array.isArray(term.aliases) || term.aliases.some(alias => typeof alias !== 'string' || !alias)) {
        throw new Error(`Invalid index term: ${term.id}`);
      }
      ids.add(term.id);
      // Chromium PDF destinations include an encoded document URL and truncate
      // long names. Keep the fragment short and stable, rejecting collisions.
      const anchor = `i${createHash('sha256').update(term.id).digest('hex').slice(0, 6)}`;
      if (anchors.has(anchor)) throw new Error(`Colliding index anchors: ${term.id}`);
      anchors.add(anchor);
      return { ...term, anchor, references: [] };
    });
  }

  addChapter(entry, markdown) {
    const nodes = [];
    function walk(node) {
      if (node.type === 'html' || node.type === 'code') return;
      if (node.type === 'text' || node.type === 'inlineCode') nodes.push(node);
      for (const child of node.children ?? []) walk(child);
    }
    walk(parser.parse(markdown));
    const insertions = new Map();
    for (const term of this.terms) {
      let selected;
      for (const node of nodes) {
        const start = node.position.start.offset;
        const raw = markdown.slice(start, node.position.end.offset);
        // Inline code remains byte-for-byte intact: place its marker before the delimiter.
        const text = node.type === 'inlineCode' ? node.value : raw;
        for (const alias of term.aliases) {
          const found = occurrence(text, alias);
          if (found < 0) continue;
          const offset = node.type === 'inlineCode' ? start : start + found;
          if (!selected || offset < selected.offset) selected = { offset, alias };
        }
      }
      if (!selected) continue;
      const anchor = term.anchor;
      const reference = { entry: entry.id, title: entry.title, anchor, alias: selected.alias };
      term.references.push(reference);
      const marker = `<span id="${anchor}" class="index-target"></span>`;
      insertions.set(selected.offset, (insertions.get(selected.offset) ?? '') + marker);
    }
    for (const [offset, marker] of [...insertions].sort((a, b) => b[0] - a[0])) {
      markdown = markdown.slice(0, offset) + marker + markdown.slice(offset);
    }
    return markdown;
  }

  render() {
    const latin = /^[A-Za-z0-9.]/;
    const sorted = this.terms.filter(term => term.references.length).sort((a, b) =>
      Number(!latin.test(a.term)) - Number(!latin.test(b.term)) || collator.compare(a.reading, b.reading));
    let group;
    const lines = [];
    for (const term of sorted) {
      const next = latin.test(term.term) ? '欧字・記号' : '五十音順';
      if (next !== group) { lines.push(`<h2>${next}</h2>`); group = next; }
      const links = term.references.map(ref =>
        `<a class="index-location" href="${ref.entry}.html#${ref.anchor}"><span class="index-label">${escapeHtml(ref.title)}</span></a>`).join('、');
      lines.push(`<p class="index-item"><span class="index-term">${escapeHtml(term.term)}</span>　${links}</p>`);
    }
    return `# 索引\n\n<div class="book-index" role="doc-index">\n${lines.join('\n')}\n</div>\n`;
  }

  manifest() { return this.terms.filter(term => term.references.length); }
}
