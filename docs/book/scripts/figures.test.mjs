import test from 'node:test';
import assert from 'node:assert/strict';
import { sha256, validateFigure, expandFigures } from './figures.mjs';

test('changed source or changed SVG cannot silently reuse an old figure', () => {
  const svg = '<svg><title>title</title><desc>description</desc></svg>';
  const input = { sourceSha256: sha256('current') };
  const artifact = { sourceSha256: input.sourceSha256, svgSha256: sha256(svg), svg };
  assert.doesNotThrow(() => validateFigure('example', input, artifact));
  assert.throws(() => validateFigure('example', { sourceSha256: sha256('changed') }, artifact), /Stale/);
  assert.throws(() => validateFigure('example', input, { ...artifact, svg: svg + 'changed' }), /Stale/);
  for (const bad of [svg.replace('<title>title</title>', ''), svg + '<foreignObject/>', svg + '<image href="https://example.com/image"/>']) {
    assert.throws(() => validateFigure('example', input, { ...artifact, svg: bad, svgSha256: sha256(bad) }), /Non-portable/);
  }
});

test('figure numbers follow chapter order; missing or duplicated references fail', () => {
  const figures = new Map([['example', { title: '表と参照', description: 'A < B & "参照"' }]]);
  const first = expandFigures('{{figure:example}}', 'task', 6, figures);
  assert.match(first.text, /図6-1/);
  assert.match(first.text, /A &lt; B &amp; &quot;参照&quot;/);
  assert.match(first.text, /src="\.\.\/figures\/example.svg"/);
  assert.deepEqual(first.used, [{ id: 'example', entry: 'task', number: '6-1' }]);
  assert.match(expandFigures('{{figure:example}}', 'task', 9, figures).text, /図9-1/);
  assert.throws(() => expandFigures('{{figure:missing}}', 'task', 6, figures), /Unknown figure/);
  assert.throws(() => expandFigures('{{figure:example}} {{figure:example}}', 'task', 6, figures), /Duplicate figure/);
});
