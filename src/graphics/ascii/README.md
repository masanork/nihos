# Built-in diagnostic console faces

The default console returns to the initial printable ASCII 8x8 bitmap in
16x16 cells (78 columns, 43 rows). Option 3 softens only exposed right/bottom
stroke edges to half coverage, with quarter coverage at their shared corner;
interior pixels and the original glyph shapes/advance remain unchanged.
Option 0 reproduces the original solid 2x bitmap. Colour is independent
of font choice; palette 3 now uses a stronger green after the pale trial
looked too white on the device. Larger outline-derived faces remain optional.

| Native font option | Face | Size | Mask bytes | Offset bytes |
| --- | --- | ---: | ---: | ---: |
| 0 | Original VGA bitmap | 8x8 at 2x | 760 | 0 |
| 3 (default) | Original VGA, lighter edges | 8x8 at 2x | 760 | 0 |
| 1 | JetBrains Mono Medium | 24 px | 10,761 | 380 |
| 2 | Source Code Pro Medium | 25 px | 10,597 | 380 |

The large-face masks use 4-bit coverage and runs of 1–16 pixels in 15x30 cells.
Only the selected face is linked into the existing read-only Flash span. The
entire source font, an outline parser and FreeType are generation-time inputs,
not native runtime dependencies. Japanese UD fonts remain deferred to the
microSD/filesystem-backed font service.

`fonts.json` pins source repository revisions, file names, SHA256 and pixel
sizes. Font copyright and OFL 1.1 terms are retained in
[JetBrainsMono-OFL.txt](JetBrainsMono-OFL.txt) and
[SourceCodePro-LICENSE.md](SourceCodePro-LICENSE.md). Generated lettering is
not a new font family. Names here identify the original source faces.

To regenerate from those exact source files:

```sh
python3 tools/console/generate-fonts.py \
  --jetbrains build/console-fonts/JetBrainsMono-Medium.ttf \
  --source-code build/console-fonts/SourceCodePro-Medium.ttf
.tools/zig-0.17.0/zig fmt src/graphics/ascii/jetbrains.zig src/graphics/ascii/source_code.zig
```

The generator rejects different font hashes and clipped glyph extents. Its
output records the Pillow and FreeType versions; those can affect rasterized
coverage, so checked-in masks are the firmware build input. The raster tests
check every decoded mask length and write guards/stride padding. The preview
uses the actual Zig renderer. The historical 760-byte `basic.bin` below is
retained as provenance for the first physically readable checkpoint.

## Initial VGA checkpoint

760 bytes: printable ASCII U+0020–U+007E, eight rows per glyph, LSB first.
Derived from Daniel Hepper's public-domain `font8x8_basic.h`, in turn derived
from Marcel Sondaar's public-domain IBM VGA font data. No Japanese font is
embedded here. Font input is pinned at commit
`8e279d2d864e79128e96188a6b9526cfa3fbfef9` of
https://github.com/dhepper/font8x8 .

Source SHA256: `49d8df366296b203ca3211bc0672cf2a762135bf12710735b6292756b19dffd5`.
Binary SHA256: `028050a3eaf7597f298b733d7c30d420265dc641ffe1405ce3d097de00d703d3`.

The source's notice states:

> Author: Daniel Hepper <daniel@hepper.net>
> License: Public Domain
> Based on font8x8.h from Marcel Sondaar (public domain IBM VGA fonts)
