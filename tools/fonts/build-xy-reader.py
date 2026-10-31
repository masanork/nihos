#!/usr/bin/env python3
"""Subset the CC0 Bunsen layers to the checked-in xy reading pack (fontTools)."""
import argparse
import hashlib
import json
from pathlib import Path
from fontTools import subset, version
from fontTools.ttLib import TTFont
from fontTools.pens.ttGlyphPen import TTGlyphPen
ROOT = Path(__file__).resolve().parents[2]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-dir', type=Path, required=True)
    args = parser.parse_args()
    library = ROOT / 'assets/xy/library.json'
    cps = set(map(ord, library.read_text())) | set(range(32,127)) | {0x25a1,0xfffd}
    out = ROOT / 'assets/xy/fonts'
    out.mkdir(parents=True, exist_ok=True)
    manifest = {'license':'CC0-1.0', 'upstream':'https://github.com/masanork/gjs', 'fonttools':version,
                'library_sha256':hashlib.sha256(library.read_bytes()).hexdigest(), 'faces': {}}
    for style in ('Mincho','Gothic'):
        covered = set(range(32,127)) | {10,13,9,0x3000,0xfffd}
        for layer in ('',):
            name = f'Bunsen{style}{layer}-Regular.ttf'
            src = args.source_dir / name
            font = TTFont(src, recalcTimestamp=False)
            covered |= set(font.getBestCmap()) & cps
            options = subset.Options()
            options.hinting = False
            options.layout_features = []
            options.drop_tables += ['GSUB','GPOS','GDEF']
            worker = subset.Subsetter(options=options)
            worker.populate(unicodes=cps)
            worker.subset(font)
            if not layer:
                pen=TTGlyphPen(None)
                font['glyf']['space']=pen.glyph()
                font['hmtx']['space']=(font['head'].unitsPerEm//2,0)
                order=font.getGlyphOrder()
                if 'space' not in order: font.setGlyphOrder(order+['space'])
                font['glyf']['ideographicspace']=pen.glyph()
                font['hmtx']['ideographicspace']=(font['head'].unitsPerEm,0)
                order=font.getGlyphOrder()
                if 'ideographicspace' not in order: font.setGlyphOrder(order+['ideographicspace'])
                for table in font['cmap'].tables:
                    if table.isUnicode():
                        table.cmap[32]='space'
                        table.cmap[0x3000]='ideographicspace'
                        if 0x25a1 in table.cmap: table.cmap[0xfffd]=table.cmap[0x25a1]
            dest=out/name
            font.save(dest)
            manifest['faces'][name]={'sha256':hashlib.sha256(dest.read_bytes()).hexdigest(), 'source_sha256':hashlib.sha256(src.read_bytes()).hexdigest(), 'bytes':dest.stat().st_size}
        manifest[style+'_missing'] = sorted(cps-covered)
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    (out/'CC0.txt').write_bytes((ROOT/'src/xy/fonts/CC0.txt').read_bytes())
    print(out, {k:v for k,v in manifest.items() if k.endswith('_missing')})

if __name__=='__main__': main()
