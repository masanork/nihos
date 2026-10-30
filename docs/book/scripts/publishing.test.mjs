import test from 'node:test';
import assert from 'node:assert/strict';
import { buildDate } from './build-date.mjs';
import { BookIndex } from './index.mjs';

const entry = { id: 'example', title: '実験' };
const term = (id, value) => ({ id, term: value, reading: value, aliases: [value] });

test('build date is Japanese time, fixed epochs repeat, and bad epochs fail', () => {
  assert.equal(buildDate({}, new Date('2026-10-26T16:00:00Z')).date, '2026年10月27日');
  assert.deepEqual(buildDate({ SOURCE_DATE_EPOCH: '0' }), buildDate({ SOURCE_DATE_EPOCH: '0' }));
  assert.equal(buildDate({ SOURCE_DATE_EPOCH: '0' }).date, '1970年1月1日');
  for (const value of ['-1', '1.5', 'bad', '', '99999999999999999999']) {
    assert.throws(() => buildDate({ SOURCE_DATE_EPOCH: value }));
  }
});

test('the index ignores code blocks, URLs and HTML attributes and preserves inline code', () => {
  const index = new BookIndex([term('dma', 'DMA'), term('heap', 'ヒープ'), term('ecall', 'ecall')]);
  const source = '# 実験\n\n```c\nDMA();\n```\n\n[参照](https://example.com/DMA)\n\n<span data-label="DMA"></span>\n\nヒープと`ecall`を調べる。DMAへ渡す。DMAを待つ。\n';
  const output = index.addChapter(entry, source);
  assert.ok(output.includes('```c\nDMA();\n```'));
  assert.ok(output.includes('https://example.com/DMA'));
  assert.ok(output.includes('data-label="DMA"'));
  assert.ok(output.includes('class="index-target"></span>`ecall`'));
  assert.ok(output.includes('class="index-target"></span>DMAへ'));
  const anchor = index.manifest().find(item => item.id === 'dma').references[0].anchor;
  assert.equal(output.split(`id="${anchor}"`).length - 1, 1);
  assert.equal(index.manifest().length, 3);
});

test('a rebuilt index follows changed text and Latin aliases use word boundaries', () => {
  const terms = [term('c', 'C'), term('zig', 'Zig')];
  const first = new BookIndex(terms);
  first.addChapter(entry, 'GCとZigzag。Zigを使う。');
  assert.deepEqual(first.manifest().map(item => item.id), ['zig']);
  const next = new BookIndex(terms);
  next.addChapter(entry, 'Cを使う。');
  assert.deepEqual(next.manifest().map(item => item.id), ['c']);
  assert.ok(!next.render().includes('Zig'));
  assert.throws(() => new BookIndex([term('same', 'A'), term('same', 'B')]));
});

test('PDF fragments stay short and do not change when chapter order or term order changes', () => {
  const first = new BookIndex([term('memory', 'メモリ'), term('dma', 'DMA')]);
  first.addChapter({ id: 'scheduler-fairness', title: '公平性' }, 'DMAとメモリ');
  const second = new BookIndex([term('dma', 'DMA'), term('memory', 'メモリ')]);
  second.addChapter({ id: 'psram-and-evidence', title: 'メモリ' }, 'DMAとメモリ');
  for (const item of first.manifest()) {
    const anchor = item.references[0].anchor;
    assert.match(anchor, /^i[0-9a-f]{6}$/);
    assert.equal(second.manifest().find(other => other.id === item.id).references[0].anchor, anchor);
    const prefix = 'viv-id-http:003a:002f:002flocalhost:003a13000:002fvivliostyle:002f_build:002fja:002fscheduler-fairness:002ehtml:0023';
    assert.ok((prefix + anchor).length < 127);
  }
});
