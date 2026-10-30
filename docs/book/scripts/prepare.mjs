import { readFile, writeFile, mkdir, access } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { dirname, resolve, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import book from '../book.cjs';
import indexTerms from '../index-terms.cjs';
import { BookIndex } from './index.mjs';
import { buildDate } from './build-date.mjs';
import { prepareFigures, expandFigures } from './figures.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const repo = resolve(root, '../..');
const output = resolve(root, '_build/ja');
const numbered = book.entries.filter(entry => entry.chapter);
const chapters = new Map(numbered.map((entry, i) => [entry.id, i + 1]));
const ids = new Set(book.entries.map(entry => entry.id));
if (ids.size !== book.entries.length) throw new Error('Duplicate book entry id');

const bookRevision = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: repo, encoding: 'utf8' }).trim();
const pinnedKernel = book.kernelRevision !== undefined;
const revision = book.kernelRevision ?? bookRevision;
if (!/^[0-9a-f]{40}$/.test(revision)) throw new Error('Kernel revision must be a full commit id');
execFileSync('git', ['cat-file', '-e', `${revision}^{commit}`], { cwd: repo });
const dirty = !pinnedKernel && execFileSync('git', ['status', '--porcelain', '--untracked-files=all', '--',
  'src', 'include', 'compat', 'main', 'tools', 'build.zig', 'build.zig.zon', '.zigversion'],
  { cwd: repo, encoding: 'utf8' }).trim().length > 0;
const bookDirty = execFileSync('git', ['status', '--porcelain', '--untracked-files=all', '--', 'docs/book'],
  { cwd: repo, encoding: 'utf8' }).trim().length > 0;
const referenceSources = {};
const manuscriptSources = {};
const index = new BookIndex(indexTerms);
const edition = buildDate();
const { figures, manifest: figureManifest } = await prepareFigures();
const figureUses = [];

function materialLink(label, file, sourceRevision, published, changed = false) {
  return published && !changed
    ? `[${label}](https://github.com/masanork/nihos/blob/${sourceRevision}/${file})`
    : label;
}

// Later case studies keep their own committed source instead of changing HEAD.
function committedSource(revision, file) {
  if (!/^[0-9a-f]{40}$/.test(revision) || !file || file.startsWith('/') ||
      file.split('/').some(part => part === '..' || part === '.')) {
    throw new Error(`Invalid committed source: ${revision}:${file}`);
  }
  return execFileSync('git', ['show', `${revision}:${file}`], { cwd: repo });
}

function knownPublic(revision) {
  try {
    execFileSync('git', ['merge-base', '--is-ancestor', revision, 'refs/remotes/origin/main'],
      { cwd: repo, stdio: 'ignore' });
    return true;
  } catch { return false; }
}

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
    end: '#if NIH_NATIVE_DISPLAY_SCANOUT',
    includeEnd: false,
    language: 'text'
  },
  'native-stack': {
    file: 'src/platform/native/start.S',
    start: '.Lstacks_ready:\n',
    end: '    la t0, __bss_start',
    includeEnd: false,
    language: 'text'
  },
  'native-main-call': {
    file: 'src/platform/native/start.S',
    start: '    call .Lsetup_vector\n    call nih_native_main',
    end: '    .global nih_native_cpu1_start',
    includeEnd: false,
    language: 'text'
  },
  'native-bss': {
    file: 'src/platform/native/esp32p4.ld',
    start: '    .bss (NOLOAD) : ALIGN(16) {',
    end: '        *(.bss .bss.* .sbss .sbss.*) *(COMMON)',
    includeEnd: true,
    language: 'text'
  },
  'native-bss-end': {
    file: 'src/platform/native/esp32p4.ld',
    start: '        . = ALIGN(16);\n        __bss_end = .;',
    end: '    .stacks (NOLOAD)',
    includeEnd: false,
    language: 'text'
  },
  'native-bss-zero': {
    file: 'src/platform/native/start.S',
    start: '    la t0, __bss_start\n',
    end: '#if NIH_NATIVE_GRAPHICS\n    la t0, __graphics_bss_start',
    includeEnd: false,
    language: 'text'
  },
  'native-boot-state': {
    file: 'src/platform/native/main.zig',
    start: 'var progress = ',
    end: 'var boot_ipi = ',
    includeEnd: false
  },
  'native-initialized-state': {
    file: 'src/platform/native/main.zig',
    start: 'var initialized: u32 = ',
    end: 'fn reg(',
    includeEnd: false
  },
  'native-crt-check': {
    file: 'src/platform/native/main.zig',
    start: '    if (progress[0] != 0 or progress[1] != 0 or',
    end: '    printBoot("NIHOS_NATIVE_CRT_PASS',
    includeEnd: false
  },
  'task-states': {
    file: 'src/kernel/scheduler.zig',
    start: 'pub const TaskState = enum(u8) {', end: '\n};', includeEnd: true
  },
  'task-exit': {
    file: 'src/kernel/scheduler.zig',
    start: '        pub fn exitCurrent(', end: '\n        }', includeEnd: true
  },
  'task-reap': {
    file: 'src/arch/riscv32/task_runtime.zig',
    start: '        pub fn reap(', end: '\n        }', includeEnd: true
  },
  'task-protection': {
    file: 'src/arch/riscv32/context.zig',
    start: 'pub const Protection = struct {', end: '\n};', includeEnd: true
  },
  'privilege-contract': {
    file: 'src/arch/riscv32/task_runtime.zig',
    start: '    fn privilegeAccepted(', end: '\n    }', includeEnd: true
  },
  'active-trap-return': {
    file: 'src/arch/riscv32/context.zig',
    start: '    pub fn returningFrom(', end: '\n    }', includeEnd: true
  },
  'ring-push': {
    file: 'src/kernel/spsc_ring.zig',
    start: '        pub fn tryPush(', end: '\n        }', includeEnd: true
  },
  'channel-send': {
    file: 'src/kernel/spsc_channel.zig',
    start: '        pub fn trySend(', end: '\n        }', includeEnd: true
  },
  'park-once': {
    file: 'src/kernel/park.zig',
    start: 'pub fn once(', end: '\n}', includeEnd: true
  },
  'core-arena-alloc': {
    file: 'src/kernel/core_arena.zig',
    start: '    pub fn alloc(', end: '\n    }', includeEnd: true
  },
  'heap-fragmentation': {
    file: 'src/kernel/buddy_heap_test.zig',
    start: 'test "isolated free leaves cannot satisfy a larger block until buddies merge" {',
    end: '\n}', includeEnd: true
  },
  'floating-context': {
    file: 'src/arch/riscv32/context.zig',
    start: 'pub const FloatingContext = extern struct {', end: '\n};', includeEnd: true
  },
  'integer-layout-check': {
    file: 'src/arch/riscv32/context.zig',
    start: '    if (@sizeOf(IntegerContext) != integer_context_size)\n',
    end: '    if (@alignOf(IntegerContext)',
    includeEnd: false
  },
  'c-pair-adapter': {
    file: 'probes/native_fp/c_math.c',
    start: 'FP_APP void nih_fp_c_pair_into(', end: '\n}', includeEnd: true, language: 'c'
  },
  'fairness-regression': {
    revision: 'd9afd649d8628aedc484bab0d50496942ffdcb5e',
    file: 'src/kernel/scheduler.zig',
    start: 'test "repeated high-priority wakes preserve round robin among lower peers" {',
    end: '\n}', includeEnd: true
  },
  'console-pixel': {
    revision: '960bb1056252aaf6193d8d66350a27e63259d26d',
    file: 'src/graphics/ascii_console.zig',
    start: 'fn pixel(', end: '\n}', includeEnd: true
  },
  'ble-command-sent': {
    revision: '94c03aae4198a4a32f03601e362fa10ea86f39b3',
    file: 'src/net/ble_hci.zig',
    start: '    pub fn sent(', end: '\n    }', includeEnd: true
  },
  'broker-unpin': {
    revision: '29cb736dc4ef8ee32d1c77fde33e6d3bfafb1239',
    file: 'src/kernel/memory_broker.zig',
    start: '        pub fn unpin(', end: '\n        }', includeEnd: true
  },
  'store-commit': {
    revision: '8b1c3c24fae826699829488c0af2834700945a4d',
    file: 'src/storage/cow_model.zig',
    start: '        pub fn commit(', end: '\n        }', includeEnd: true
  },
  'c-allocator-api': {
    revision: 'edbdd6cdbc4ff19d5d1a46f20510abd6d6789608',
    file: 'include/nihos_allocator.h',
    start: 'void *nih_task_malloc(', end: '\n#endif', includeEnd: false, language: 'c'
  },
  'sqlite-vfs-sync': {
    revision: '6bb2467ac14e7cc90b4bc2dde3f45c72360ca420',
    file: 'probes/sqlite/store_vfs.c',
    start: 'static int sync_file(', end: '\n}', includeEnd: true, language: 'c'
  },
  'font-map-error': {
    revision: '9e784cf9cde6bd19abb1cf205528ff3b086faaf5',
    file: 'probes/graphics/patches/freetype-autofit-map-error.patch',
    start: '@@ -1162,8 +1162,8 @@\n',
    end: '\n     face->charmap = oldmap;', includeEnd: true, language: 'diff'
  },
  'audio-cleanup': {
    revision: 'ae248b92c0d3b675c4650340f0e184ea9744cea5',
    file: 'src/audio/playback_probe.zig',
    start: '        fn cleanup(', end: '\n        }', includeEnd: true
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
  const sourceRevision = spec.revision ?? revision;
  const published = knownPublic(sourceRevision);
  const text = spec.revision || pinnedKernel
    ? committedSource(sourceRevision, spec.file).toString('utf8')
    : await readFile(resolve(repo, spec.file), 'utf8');
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
  const url = `https://github.com/masanork/nihos/blob/${sourceRevision}/${spec.file}#L${startLine}`;
  const fileDirty = !spec.revision && !pinnedKernel && execFileSync('git', ['status', '--porcelain', '--untracked-files=all', '--', spec.file],
    { cwd: repo, encoding: 'utf8' }).trim().length > 0;
  const label = fileDirty ? `${sourceRevision.slice(0, 12)} + 作業中の変更` : sourceRevision.slice(0, 12);
  const note = fileDirty
    ? `${spec.file}、${label}（リンクは変更前のコミット）`
    : `${spec.file}、${label}`;
  const language = spec.language ?? 'zig';
  snippetSources[id] = {
    file: spec.file, revision: sourceRevision, published, startLine, language,
    sourceSha256: createHash('sha256').update(text).digest('hex'),
    snippetSha256: createHash('sha256').update(code).digest('hex')
  };
  const sourceNote = published ? `<a href="${url}">${note}</a>` : `${note}（ローカル保存版）`;
  renderedSnippets.set(id, `\n\n\`\`\`${language}\n${code}\n\`\`\`\n\n<p class="source-note">出典: ${sourceNote}。</p>\n`);
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
  } else if (entry.id === 'index') {
    text = index.render();
  } else {
    text = await readFile(resolve(root, `ja/${entry.id}.md`), 'utf8');
    manuscriptSources[`ja/${entry.id}.md`] = createHash('sha256').update(text).digest('hex');
    if (/^# 第\d+章/m.test(text)) throw new Error(`Hard-coded chapter number: ${entry.id}`);
    if (entry.chapter) {
      if (!text.startsWith(`# ${entry.title}\n`)) throw new Error(`Title mismatch: ${entry.id}`);
      text = text.replace(/^# /, `# 第${chapters.get(entry.id)}章　`);
    }
    // A local file may not exist at HEAD yet. Never invent its public URL.
    for (const match of text.matchAll(/\[([^\]\n]+)\]\((git:([0-9a-f]{40}):([^)]+))\)/g)) {
      const [, label, href, sourceRevision, path] = match;
      const source = committedSource(sourceRevision, path);
      const published = knownPublic(sourceRevision);
      referenceSources[href] = {
        revision: sourceRevision, file: path,
        sourceSha256: createHash('sha256').update(source).digest('hex'),
        committed: true, changed: false, published
      };
      const replacement = materialLink(label, path, sourceRevision, published);
      text = text.replaceAll(match[0], replacement);
    }
    for (const match of text.matchAll(/\[([^\]\n]+)\]\((repo:[^)]+)\)/g)) {
      const [, label, href] = match;
      const path = href.slice(5);
      const target = resolve(repo, path);
      if (!target.startsWith(repo + sep)) throw new Error(`Path outside repo: ${href}`);
      const source = pinnedKernel ? committedSource(revision, path) : await readFile(target);
      let committed = true;
      try {
        execFileSync('git', ['cat-file', '-e', `${revision}:${path}`], { cwd: repo, stdio: 'ignore' });
      } catch { committed = false; }
      const changed = !pinnedKernel && execFileSync('git', ['status', '--porcelain', '--untracked-files=all', '--', path],
        { cwd: repo, encoding: 'utf8' }).trim().length > 0;
      const published = committed && knownPublic(revision);
      referenceSources[path] = { revision, file: path, sourceSha256: createHash('sha256').update(source).digest('hex'), committed, changed, published };
      const replacement = materialLink(label, path, revision, published, changed);
      text = text.replaceAll(match[0], replacement);
    }
    // Check remaining links after resolving repository references.
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
    text = text.replaceAll('{{build-date}}', edition.date);
    const expanded = expandFigures(text, entry.id, chapters.get(entry.id), figures);
    text = expanded.text;
    figureUses.push(...expanded.used);
    if (/\{\{[^}]+\}\}/.test(text)) throw new Error(`Unresolved placeholder: ${entry.id}`);
    text = text.replace(/\]\(([\w-]+)\.md(#[^)]*)?\)/g, ']($1.html$2)');
    if (entry.chapter || entry.id === 'why-os') text = index.addChapter(entry, text);
  }
  await writeFile(resolve(output, `${entry.id}.md`), text);
}
await writeFile(resolve(root, '_build/source.json'), JSON.stringify({
  revision, bookRevision, kernelDirty: dirty, edition,
  bookDirty, manuscriptSources, referenceSources,
  snippets: Object.fromEntries(Object.entries(snippets).map(([id, spec]) => [id, spec.file])),
  snippetSources,
  figures: { ...figureManifest, uses: figureUses },
  index: {
    source: 'index-terms.cjs',
    sourceSha256: createHash('sha256').update(await readFile(resolve(root, 'index-terms.cjs'))).digest('hex'),
    entries: index.manifest()
  }
}, null, 2) + '\n');
console.log(`Prepared ${book.entries.length} entries in ${relative(root, output)}; source ${revision.slice(0, 12)}${dirty ? ' (modified)' : ''}`);
