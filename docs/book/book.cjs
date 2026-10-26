// Chapter order is editorial data; only entries with chapter: true are numbered.
module.exports = {
  title: '小さなOSを育てる',
  subtitle: 'ZigとRISC-Vで学ぶ、実機のしくみと設計判断',
  author: 'nihos project',
  entries: [
    { id: 'cover', title: '表紙' },
    { id: 'preface', title: 'はじめに' },
    { id: 'toc', title: '目次', rel: 'contents' },
    { id: 'boundaries', title: '動く端末からOSを考える', chapter: true },
    { id: 'first-experiment', title: '最初の実験を再現する', chapter: true },
    { id: 'bounded-memory', title: '有限のメモリを誰が持つか', chapter: true },
    { id: 'native-entry', title: 'Zigが動き始めるまで', chapter: true },
    { id: 'colophon', title: 'この試読版について' }
  ]
};
