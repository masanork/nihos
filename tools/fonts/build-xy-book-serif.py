#!/usr/bin/env python3
"""Build a renamed, reproducible quadratic Schola subset for the xy reader."""
from pathlib import Path
import hashlib
import json
from fontTools import subset, version
from fontTools.fontBuilder import FontBuilder
from fontTools.ttLib import TTFont
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.pens.cu2quPen import Cu2QuPen
ROOT = Path(__file__).resolve().parents[2]
SOURCE_SHA = '935b82e25f56b1d1276ca82793205e8ce254fbb37ebd38bedf7388cef21fbf44'

def main():
    source = ROOT/'third_party/xy-typography/texgyreschola-regular.otf'
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    if digest != SOURCE_SHA: raise ValueError('Unexpected Schola source')
    font = TTFont(source, recalcTimestamp=False)
    options = subset.Options(); options.hinting = False; options.layout_features = []
    worker = subset.Subsetter(options=options)
    worker.populate(unicodes=set(range(32, 0x250)) | set(range(0x2000,0x2070)))
    worker.subset(font)
    order = font.getGlyphOrder(); glyphs = {}; source_glyphs = font.getGlyphSet()
    for name in order:
        pen = TTGlyphPen(None)
        source_glyphs[name].draw(Cu2QuPen(pen, max_err=1.0, reverse_direction=True))
        glyphs[name] = pen.glyph()
    fb = FontBuilder(font['head'].unitsPerEm, isTTF=True)
    fb.setupGlyphOrder(order); fb.setupCharacterMap(font.getBestCmap()); fb.setupGlyf(glyphs)
    fb.setupHorizontalMetrics(font['hmtx'].metrics)
    fb.setupHorizontalHeader(ascent=font['hhea'].ascent, descent=font['hhea'].descent)
    fb.setupNameTable({'familyName':'nihos Book Serif','styleName':'Regular',
        'uniqueFontIdentifier':'nihosBookSerif-Schola-2.005-v1', 'fullName':'nihos Book Serif Regular',
        'psName':'nihosBookSerif-Regular', 'version':'Version 1.000',
        'copyright':font['name'].getDebugName(0), 'licenseDescription':'GUST Font License / LPPL 1.3c',
        'licenseInfoURL':'https://www.gust.org.pl/fonts/licenses/GUST-FONT-LICENSE.txt'})
    fb.setupOS2(sTypoAscender=font['OS/2'].sTypoAscender, sTypoDescender=font['OS/2'].sTypoDescender,
                usWinAscent=font['OS/2'].usWinAscent, usWinDescent=font['OS/2'].usWinDescent)
    fb.setupPost(); fb.setupMaxp(); fb.font['head'].created=fb.font['head'].modified=2082844800
    out=ROOT/'src/graphics/serif';out.mkdir(exist_ok=True)
    dest=out/'nihos-book-serif.ttf'; fb.save(dest)
    manifest={'source':'https://mirrors.ctan.org/fonts/tex-gyre/opentype/texgyreschola-regular.otf',
        'source_sha256':digest,'source_family':'TeX Gyre Schola','source_version':'2.005',
        'license':'GUST Font License / LPPL 1.3c','fonttools':version,
        'changes':'Renamed; Latin subset; cubic to quadratic outlines, maximum error 1 font unit; no hints or layout tables.',
        'output_sha256':hashlib.sha256(dest.read_bytes()).hexdigest(),'bytes':dest.stat().st_size}
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(manifest)
if __name__=='__main__': main()
