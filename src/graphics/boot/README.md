# Embedded boot lettering

`assets.zig` and `masks.rle` are generated from **Noto Serif CJK JP Regular**,
under the SIL Open Font License 1.1. The copyright notice and full license are
in [OFL.txt](OFL.txt); font provenance is in [provenance.toml](provenance.toml).
The masks are fixed lettering, not a general-purpose font subset or font engine.

The firmware embeds 74 sprites sharing masks totalling **38,085 bytes**. Each byte encodes
4 bits of coverage and a run of 1–16 pixels. Masks are drawn directly into
the borrowed RGB565 framebuffer, with no heap allocation or file access.
The platform's existing scanout allocation remains separate (1,843,200 bytes).

To regenerate from the pinned font (Pillow 11.3.0 was used):

```sh
mkdir -p build/boot-font
curl -fL https://raw.githubusercontent.com/notofonts/noto-cjk/f8d157532fbfaeda587e826d4cd5b21a49186f7c/Serif/OTF/Japanese/NotoSerifCJKjp-Regular.otf \
  -o build/boot-font/NotoSerifCJKjp-Regular.otf
# Expected SHA256: d9854c7a8ef170b5a7932558856fd64eb8de0b007cd823fed6f9f514ad2803d3
python3 tools/boot-graphics/generate.py build/boot-font/NotoSerifCJKjp-Regular.otf
.tools/zig-0.17.0/zig fmt src/graphics/boot/assets.zig
```

The entire font is a generation-time input and is not committed or linked.
Ordinary firmware builds and host tests use the checked-in masks and need
neither Pillow nor a font download.


The native full-frame boot uses a 1280x720 landscape composition: a title on
its left and the vertically written poem on its right. Logical `(x,y)` maps
to physical `(y,1279-x)`, matching MeOS's keyboard orientation, inside the same
720x1280 framebuffer. The portrait API remains available to the hosted port
and the bring-up tile diagnostics. Preview defaults to landscape; pass
`--layout portrait` for the other composition.

The inscription uses `穗 / 經 / 將`, with the credit `萬葉集　卷十六・三八〇一`.
These old-form glyphs are an explicit visual treatment of the user's supplied
transcription, not a claim to reproduce a particular manuscript's glyphs.
The original `寐` and the repeated `丹` are retained. Editions may transcribe
the latter with an iteration mark; no reading or wording is silently changed.
Only the three `丹穗` pairs and the state marker gain vermilion. The legacy native
animation holds monochrome for about one second, then fades over about two
seconds at the 60 Hz target. That legacy mode is a visual introduction. Opt-in live console mode instead
advances the dye target at memory/core/console milestones, with no fixed hold.

Text reference: [Manyoshu 16-3801](https://manyoshu-japan.com/9777/).
Font provenance and the OFL apply equally to both sets of masks.
