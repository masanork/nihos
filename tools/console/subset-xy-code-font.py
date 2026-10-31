#!/usr/bin/env python3
"""Reproduce the shared printable-ASCII Source Code Pro recovery face."""
import hashlib
import json
from pathlib import Path
from fontTools import subset
from fontTools.ttLib import TTFont

root = Path(__file__).resolve().parents[2]
source = root / 'src/graphics/ascii/SourceCodePro-Medium.ttf'
expected = 'f9dbc746f60c83f5cb1503b19f90729d8195cab6bb67f2b861d4eb257ed86536'
if hashlib.sha256(source.read_bytes()).hexdigest() != expected:
    raise ValueError('Pinned Source Code Pro source mismatch')
font = TTFont(source, recalcTimestamp=False)
options = subset.Options()
options.hinting = False
options.layout_features = []
options.name_IDs = ['*']
options.name_languages = ['*']
subsetter = subset.Subsetter(options=options)
subsetter.populate(unicodes=range(32, 127))
subsetter.subset(font)
# Respect the upstream Reserved Font Name for the modified subset.
for record in font['name'].names:
    names = {1: 'Nihos Code', 2: 'Medium', 3: 'NihosCode-Medium-ASCII', 4: 'Nihos Code Medium', 6: 'NihosCode-Medium', 16: 'Nihos Code', 17: 'Medium'}
    if record.nameID in names:
        record.string = names[record.nameID].encode(record.getEncoding())
target = root / 'src/graphics/ascii/nihos-code.ttf'
font.save(target)
manifest = {'source_sha256': expected, 'sha256': hashlib.sha256(target.read_bytes()).hexdigest(), 'bytes': target.stat().st_size, 'codepoints': [32, 126], 'license': 'OFL-1.1; SourceCodePro-LICENSE.md', 'scope': 'ASCII recovery subset; shared renderer output compared to the original for every printable ASCII glyph'}
(root / 'src/graphics/ascii/nihos-code.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest))
