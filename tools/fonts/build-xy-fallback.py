#!/usr/bin/env python3
"""Build bounded, unhinted boot faces from the CC0 Bunsen fonts (fontTools)."""
import argparse
import hashlib
import json
from pathlib import Path
from fontTools import subset, version
from fontTools.ttLib import TTFont
from fontTools.pens.ttGlyphPen import TTGlyphPen

ROOT = Path(__file__).resolve().parents[2]
DEST = ROOT / 'src/xy/fonts'
# A boot/recovery face, not a replacement for the complete FontBLOB family.
TEXT = '日本語表示入力文字字体明朝青空文庫読書設定編集保存実行終了削除取消確認移動戻上下載込色背景本文行間余白状態記録作業領域'
CODEPOINTS = sorted(set(range(32, 127)) | set(range(0x3000, 0x3100)) | {ord(c) for c in TEXT} | {0x25a1, 0xfffd})

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-dir', type=Path, required=True)
    args = parser.parse_args()
    manifest = {'purpose': 'ROM boot/recovery subset; complete Japanese coverage requires an external font reader', 'license': 'CC0-1.0', 'upstream': 'https://github.com/masanork/gjs', 'fonttools': version, 'faces': {}}
    for style in ('Mincho', 'Gothic'):
        source = args.source_dir / f'Bunsen{style}-Regular.ttf'
        font = TTFont(source, recalcTimestamp=False)
        options = subset.Options()
        options.hinting = False
        options.layout_features = []
        options.drop_tables += ['GSUB', 'GPOS', 'GDEF']
        worker = subset.Subsetter(options=options)
        worker.populate(unicodes=CODEPOINTS)
        worker.subset(font)
        # Real empty space, rather than asking the renderer to invent a visible glyph.
        pen = TTGlyphPen(None)
        font['glyf']['space'] = pen.glyph()
        font['hmtx']['space'] = (font['head'].unitsPerEm // 2, 0)
        order = font.getGlyphOrder()
        if 'space' not in order:
            font.setGlyphOrder(order + ['space'])
        for table in font['cmap'].tables:
            if table.isUnicode():
                table.cmap[32] = 'space'
                if 0x25a1 in table.cmap:
                    table.cmap[0xfffd] = table.cmap[0x25a1]
        font['name'].setName(f'Nihos Boot {style}', 1, 3, 1, 0x409)
        font['name'].setName(f'NihosBoot{style}', 6, 3, 1, 0x409)
        output = DEST / f'{style.lower()}.ttf'
        font.save(output, reorderTables=True)
        manifest['faces'][style.lower()] = {'source': source.name, 'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(), 'sha256': hashlib.sha256(output.read_bytes()).hexdigest(), 'bytes': output.stat().st_size, 'codepoints': sorted(font.getBestCmap())}
    (DEST / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')

if __name__ == '__main__':
    main()
