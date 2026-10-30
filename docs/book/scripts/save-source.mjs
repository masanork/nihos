import { copyFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const format = process.argv[2];
if (!['pdf', 'web'].includes(format)) throw new Error('Expected pdf or web');
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
await copyFile(resolve(root, '_build/source.json'), resolve(root, `output/${format}/source.json`));
