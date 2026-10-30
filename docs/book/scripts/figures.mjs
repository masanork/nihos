import { readFile, readdir, mkdir, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const bookRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const sha256 = value => createHash('sha256').update(value).digest('hex');
const escape = value => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

export async function figureInputs(root = bookRoot) {
  const configBytes = await readFile(resolve(root, 'figures/config.json'));
  const config = JSON.parse(configBytes);
  const versions = {};
  for (const name of ['@mermaid-js/mermaid-cli', 'mermaid']) {
    versions[name] = JSON.parse(await readFile(resolve(root, 'node_modules', name, 'package.json'))).version;
  }
  const sources = {};
  for (const file of (await readdir(resolve(root, 'figures'))).filter(file => file.endsWith('.mmd')).sort()) {
    const id = file.slice(0, -4);
    if (!/^[a-z][a-z0-9-]*$/.test(id)) throw new Error(`Invalid figure id: ${id}`);
    const source = await readFile(resolve(root, 'figures', file), 'utf8');
    const title = source.match(/^\s*accTitle:\s*(.+)$/m)?.[1];
    const description = source.match(/^\s*accDescr:\s*(.+)$/m)?.[1];
    if (!title || !description) throw new Error(`Missing accTitle/accDescr: ${file}`);
    sources[id] = { file: `figures/${file}`, source, title, description, sourceSha256: sha256(source) };
  }
  return { config, configSha256: sha256(configBytes), versions, sources };
}

export function validateFigure(id, input, artifact) {
  if (!artifact || artifact.sourceSha256 !== input.sourceSha256 ||
      artifact.svgSha256 !== sha256(artifact.svg)) {
    throw new Error(`Stale or missing figure: ${id}; run npm run figures`);
  }
  if (!/<svg\b/.test(artifact.svg) || !/<title\b/.test(artifact.svg) || !/<desc\b/.test(artifact.svg) ||
      /<foreignObject\b|<script\b|(?:href|src)=["'](?:https?:|file:)/i.test(artifact.svg)) {
    throw new Error(`Non-portable or inaccessible SVG: ${id}`);
  }
}

export async function prepareFigures(root = bookRoot) {
  const inputs = await figureInputs(root);
  const manifest = JSON.parse(await readFile(resolve(root, 'figures/generated/manifest.json')));
  if (manifest.configSha256 !== inputs.configSha256 ||
      JSON.stringify(manifest.versions) !== JSON.stringify(inputs.versions) ||
      JSON.stringify(Object.keys(manifest.figures).sort()) !== JSON.stringify(Object.keys(inputs.sources).sort())) {
    throw new Error('Figure configuration, versions or inventory changed; run npm run figures');
  }
  const figures = new Map();
  await mkdir(resolve(root, '_build/figures'), { recursive: true });
  for (const [id, input] of Object.entries(inputs.sources)) {
    const svg = await readFile(resolve(root, 'figures/generated', `${id}.svg`), 'utf8');
    validateFigure(id, input, { ...manifest.figures[id], svg });
    await writeFile(resolve(root, '_build/figures', `${id}.svg`), svg);
    figures.set(id, { ...input, ...manifest.figures[id] });
  }
  return { figures, manifest };
}

export function expandFigures(markdown, entryId, chapter, figures) {
  const used = [];
  const text = markdown.replace(/\{\{figure:([\w-]+)\}\}/g, (_, id) => {
    const figure = figures.get(id);
    if (!figure) throw new Error(`Unknown figure in ${entryId}: ${id}`);
    if (used.some(item => item.id === id)) throw new Error(`Duplicate figure in ${entryId}: ${id}`);
    const number = `${chapter}-${used.length + 1}`;
    used.push({ id, entry: entryId, number });
    return `\n\n<figure class="book-figure" id="f${sha256(`${entryId}:${id}`).slice(0, 6)}">\n` +
      `<img src="../figures/${id}.svg" alt="${escape(figure.description)}" />\n` +
      `<figcaption>図${number}　${escape(figure.title)}</figcaption>\n</figure>\n\n`;
  });
  return { text, used };
}
