import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
const bytes = await readFile(process.argv[2]);
let instance, calls = [], fail = false;
const decoder = new TextDecoder('utf-8', { fatal: true });
function readText(ptr, len) {
  ptr >>>= 0; len >>>= 0;
  const memory = instance.exports.memory.buffer;
  if (ptr > memory.byteLength || len > memory.byteLength - ptr || len > 128) throw new RangeError('invalid range');
  return decoder.decode(new Uint8Array(memory, ptr, len));
}
const imports = { nihos: {
  nih_app_fill_rect(x,y,w,h,rgb) { calls.push(['rect',x,y,w>>>0,h>>>0,rgb>>>0]); return fail ? -4 : 0; },
  nih_app_text(x,y,ptr,len,rgb) {
    let value;
    try { value = readText(ptr,len); } catch (error) { if (error instanceof TypeError) return -2; throw error; }
    if ([...value].some(ch => ch.codePointAt(0) < 32 || ch.codePointAt(0) > 126)) return -2;
    calls.push(['text',x,y,value,rgb>>>0]); return 0;
  },
}};
({instance} = await WebAssembly.instantiate(bytes, imports));
assert.equal(instance.exports.nih_rust_app_frame(0), 0);
assert.deepEqual(calls, [['rect',0,0,160,80,0x101010],['text',8,8,'Ready',0xffffff]]);
calls = [];
assert.equal(instance.exports.nih_rust_app_frame(1), 0);
assert.deepEqual(calls, [['rect',0,0,160,80,0x204060],['text',8,8,'Pressed',0xffffff]]);
calls = []; fail = true;
assert.equal(instance.exports.nih_rust_app_frame(1), -4);
assert.equal(calls.length, 1);
calls = [];
assert.equal(instance.exports.nih_rust_app_frame(2), -1);
assert.equal(calls.length, 0);
assert.throws(() => readText(-1,2), RangeError);
assert.throws(() => readText(instance.exports.memory.buffer.byteLength,1), RangeError);
assert.throws(() => imports.nihos.nih_app_text(0,0,-1,2,0), RangeError);
const last = instance.exports.memory.buffer.byteLength - 1;
new Uint8Array(instance.exports.memory.buffer)[last] = 0xff;
assert.equal(imports.nihos.nih_app_text(0,0,last,1,0), -2);
assert.equal(instance.exports.nih_probe_bad_text(), -2);
assert.throws(() => instance.exports.nih_probe_raw_text(-1,2), RangeError);
console.log('Same Rust app, Wasm imports and range checks: ok');
