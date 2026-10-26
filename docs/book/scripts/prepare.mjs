import { readFile, writeFile, mkdir, access } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { dirname, resolve, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import book from '../book.cjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const repo = resolve(root, '../..');
const output = resolve(root, '_build/ja');
const numbered = book.entries.filter(entry => entry.chapter);
const chapters = new Map(numbered.map((entry, i) => [entry.id, i + 1]));
const ids = new Set(book.entries.map(entry => entry.id));
if (ids.size !== book.entries.length) throw new Error('Duplicate book entry id');

const revision = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: repo, encoding: 'utf8' }).trim();
const dirty = execFileSync('git', ['status', '--porcelain', '--untracked-files=all', '--',
  'src', 'include', 'compat', 'main', 'tools', 'build.zig', 'build.zig.zon', '.zigversion'],
  { cwd: repo, encoding: 'utf8' }).trim().length > 0;

// Exact unique anchors fail closed if the source changes. Never copy code into prose.
const snippets = {
  'boot-info': {
    file: 'src/platform/abi.zig',
    start: 'pub const BootInfo = extern struct {',
    end: '\n};',
    includeEnd: true
  },
  'arena-alloc': {
    file: 'src/kernel/arena.zig',
    start: '    pub fn alloc(',
    end: '    pub fn remaining(',
    includeEnd: false
  },
  'native-entry': {
    file: 'src/platform/native/start.S',
    start: 'nih_native_start:\n',
    end: '    .global nih_native_cpu1_start',
    includeEnd: false,
    language: 'text'
  },
  'native-bss': {
    file: 'src/platform/native/esp32p4.ld',
    start: '    .bss (NOLOAD) : ALIGN(16) {',
    end: '    .stacks (NOLOAD)',
    includeEnd: false,
    language: 'text'
  },
  'native-boot-state': {
    file: 'src/platform/native/main.zig',
    start: 'var progress = ',
    end: 'fn reg(',
    includeEnd: false
  },
  'native-crt-check': {
    file: 'src/platform/native/main.zig',
    start: '    if (progress[0] != 0 or progress[1] != 0 or',
    end: '    print("NIHOS_NATIVE_CRT_PASS',
    includeEnd: false
  }
};

function uniqueIndex(text, anchor, label, offset = 0) {
  const index = text.indexOf(anchor, offset);
  if (index < 0 || text.indexOf(anchor, index + anchor.length) >= 0) {
    throw new Error(`Missing or ambiguous ${label}: ${anchor}`);
  }
  return index;
}

const renderedSnippets = new Map();
const snippetSources = {};
for (const [id, spec] of Object.entries(snippets)) {
  const text = await readFile(resolve(repo, spec.file), 'utf8');
  const start = uniqueIndex(text, spec.start, spec.file);
  // A closing brace is deliberately searched only up to the next declaration.
  const end = spec.includeEnd
    ? text.indexOf(spec.end, start + spec.start.length)
    : uniqueIndex(text, spec.end, spec.file, start + spec.start.length);
  if (end < start) throw new Error(`Missing snippet end: ${id}`);
  const source = text.slice(start, end + (spec.includeEnd ? spec.end.length : 0)).trimEnd();
  const lines = source.split('\n');
  const indent = Math.min(...lines.filter(line => line.trim()).map(line => line.match(/^ */)[0].length));
  const code = lines.map(line => line.slice(indent)).join('\n');
  const startLine = text.slice(0, start).split('\n').length;
  const url = `https://github.com/masanork/nihos/blob/${revision}/${spec.file}#L${startLine}`;
  const fileDirty = execFileSync('git', ['status', '--porcelain', '--untracked-files=all', '--', spec.file],
    { cwd: repo, encoding: 'utf8' }).trim().length > 0;
  const label = fileDirty ? `${revision.slice(0, 12)} + 作業中の変更` : revision.slice(0, 12);
  const note = fileDirty
    ? `${spec.file}、${label}（リンクは変更前のコミット）`
    : `${spec.file}、${label}`;
  const language = spec.language ?? 'zig';
  snippetSources[id] = {
    file: spec.file, startLine, language,
    sourceSha256: createHash('sha256').update(text).digest('hex'),
    snippetSha256: createHash('sha256').update(code).digest('hex')
  };
  renderedSnippets.set(id, `\n\n\`\`\`${language}\n${code}\n\`\`\`\n\n出典: [${note}](${url})。\n`);
}

await mkdir(output, { recursive: true });
for (const entry of book.entries) {
  let text;
  if (entry.id === 'toc') {
    const links = book.entries.filter(item => !['cover', 'toc'].includes(item.id)).map(item => {
      const prefix = chapters.has(item.id) ? `第${chapters.get(item.id)}章　` : '';
      return `- [${prefix}${item.title}](${item.id}.html)`;
    });
    text = `<nav role="doc-toc">\n\n# 目次\n\n${links.join('\n')}\n\n</nav>\n`;
  } else {
    text = await readFile(resolve(root, `ja/${entry.id}.md`), 'utf8');
    if (/^# 第\d+章/m.test(text)) throw new Error(`Hard-coded chapter number: ${entry.id}`);
    if (entry.chapter) {
      if (!text.startsWith(`# ${entry.title}\n`)) throw new Error(`Title mismatch: ${entry.id}`);
      text = text.replace(/^# /, `# 第${chapters.get(entry.id)}章　`);
    }
    // Check repository links before converting them to commit-bound source links.
    for (const match of text.matchAll(/\]\(([^)]+)\)/g)) {
      const href = match[1];
      if (/^(https?:|mailto:|#)/.test(href)) continue;
      if (href.startsWith('repo:')) {
        const path = href.slice(5);
        const target = resolve(repo, path);
        if (!target.startsWith(repo + sep)) throw new Error(`Path outside repo: ${href}`);
        await access(target);
        text = text.replaceAll(`](${href})`, `](https://github.com/masanork/nihos/blob/${revision}/${path})`);
      } else if (!ids.has(href.replace(/\.(md|html)(#.*)?$/, ''))) {
        throw new Error(`Unknown local link in ${entry.id}: ${href}`);
      }
    }
    text = text.replace(/\{\{ch:([\w-]+)\}\}/g, (_, id) => {
      if (!chapters.has(id)) throw new Error(`Unknown chapter reference: ${id}`);
      return `第${chapters.get(id)}章`;
    });
    text = text.replace(/\{\{snippet:([\w-]+)\}\}/g, (_, id) => {
      if (!renderedSnippets.has(id)) throw new Error(`Unknown snippet: ${id}`);
      return renderedSnippets.get(id);
    });
    text = text.replaceAll('{{source-revision}}', `${revision}${dirty ? ' + 作業中の変更' : ''}`);
    if (/\{\{[^}]+\}\}/.test(text)) throw new Error(`Unresolved placeholder: ${entry.id}`);
    text = text.replace(/\]\(([\w-]+)\.md(#[^)]*)?\)/g, ']($1.html$2)');
  }
  await writeFile(resolve(output, `${entry.id}.md`), text);
}
await writeFile(resolve(root, '_build/source.json'), JSON.stringify({
  revision, kernelDirty: dirty,
  snippets: Object.fromEntries(Object.entries(snippets).map(([id, spec]) => [id, spec.file])),
  snippetSources
}, null, 2) + '\n');
console.log(`Prepared ${book.entries.length} entries in ${relative(root, output)}; source ${revision.slice(0, 12)}${dirty ? ' (modified)' : ''}`);
