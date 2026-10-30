const book = require('./book.cjs');

module.exports = {
  title: `${book.title} - ${book.subtitle}`,
  author: book.author,
  language: 'ja',
  size: 'A5',
  copyAsset: { excludes: ['tmp/**', 'output/**', 'node_modules/**'] },
  toc: { title: '目次' },
  // Resolve the lockfile-installed theme, rather than fetching a floating npm name.
  theme: ['./node_modules/@vivliostyle/theme-techbook', './custom.css'],
  entry: book.entries.map(({ id, title, rel }) => ({
    path: `_build/ja/${id}.md`,
    title,
    ...(rel ? { rel } : {})
  })),
  output: [{ path: 'output/pdf/nihos-book-sample.pdf', format: 'pdf' }],
  timeout: 180000
};
