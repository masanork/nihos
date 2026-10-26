# Embedded boot lettering

`assets.zig` and `masks.rle` are generated from **Noto Serif CJK JP Regular**,
under the SIL Open Font License 1.1. The copyright notice and full license are
in [OFL.txt](OFL.txt); font provenance is in [provenance.toml](provenance.toml).
The masks are fixed lettering, not a general-purpose font subset or font engine.

The firmware embeds 36 masks totalling **28,366 bytes**. Each byte encodes
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
