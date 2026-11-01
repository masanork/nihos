import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
const bytes = await readFile(process.argv[2]);
const { instance } = await WebAssembly.instantiate(bytes, { nihos: {
  nih_app_fill_rect() { return 0; }, nih_app_text() { return 0; },
}});
const e = instance.exports;
assert.equal(e.nih_probe_unaligned(0xfedcba9876543210n), BigInt.asIntN(64, 0xfedcba9876543210n));
assert.equal(e.nih_probe_indirect(0, 11), 18);
assert.equal(e.nih_probe_indirect(1, 0x12345678) >>> 0, (0x12345678 ^ 0xa5a55a5a) >>> 0);
assert.equal(e.nih_probe_nested(47), 48);
assert.equal(e.nih_probe_wide(0x0123456789abcdefn), 0n);
assert.equal(e.nih_probe_grow(1) >>> 0, 0xffffffff);
assert.throws(() => e.nih_probe_corpus_trap(), WebAssembly.RuntimeError);
assert.equal(e.nih_probe_nested(1), 2);
console.log('Independent Wasm engine: unaligned i64, indirect calls, recursion, growth rejection and trap recovery passed');
