import { mkdir, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import puppeteer from 'puppeteer';
import { renderMermaid } from '@mermaid-js/mermaid-cli';
import { bookRoot, figureInputs, sha256, validateFigure } from './figures.mjs';

const inputs = await figureInputs();
const browser = await puppeteer.launch({ headless: true });
const figures = {};
try {
  await mkdir(resolve(bookRoot, 'figures/generated'), { recursive: true });
  for (const [id, input] of Object.entries(inputs.sources)) {
    const result = await renderMermaid(browser, input.source, 'svg', {
      mermaidConfig: { ...inputs.config, deterministicIDSeed: id },
      viewport: { width: 1200, height: 1000, deviceScaleFactor: 1 },
      backgroundColor: 'white', fontEmbed: false, svgId: `diagram-${id}`
    });
    const svg = Buffer.from(result.data).toString('utf8');
    const artifact = { sourceSha256: input.sourceSha256, svgSha256: sha256(svg) };
    validateFigure(id, input, { ...artifact, svg });
    const viewBox = svg.match(/viewBox="([^"]+)"/)?.[1];
    if (!viewBox) throw new Error(`Missing SVG dimensions: ${id}`);
    figures[id] = { ...artifact, file: input.file, title: input.title, description: input.description, viewBox };
    await writeFile(resolve(bookRoot, 'figures/generated', `${id}.svg`), svg);
    console.log(`Rendered ${id}: ${viewBox}`);
  }
  await writeFile(resolve(bookRoot, 'figures/generated/manifest.json'), JSON.stringify({
    versions: inputs.versions, configSha256: inputs.configSha256,
    browser: await browser.version(), figures
  }, null, 2) + '\n');
} finally { await browser.close(); }
