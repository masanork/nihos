#!/usr/bin/env python3
"""Regenerate the 96x96, 1-bit Form 7 mark used by the Tab5 UI.

Geometry adapted from Shinichi Ohki's CC0 SVG:
https://gist.github.com/Shinichi-Ohki/5425a47f67c3650a96ed51749012b6e0
Reference: https://laws.e-gov.go.jp/data/MinisterialOrdinance/356M50001000037/635531_1/pict/2FH00000083024.pdf
"""
from pathlib import Path
from PIL import Image, ImageDraw

image = Image.new('1', (640, 640))
draw = ImageDraw.Draw(image)
draw.arc((40, 40, 600, 600), start=22, end=346, fill=1, width=40)
draw.polygon([(598, 210), (340, 271), (340, 181), (27, 256), (22, 296),
              (300, 230), (300, 320), (610, 246)], fill=1)
draw.rectangle((160, 340, 479, 389), fill=1)
draw.rectangle((160, 420, 479, 469), fill=1)
draw.rectangle((290, 470, 349, 549), fill=1)
draw.polygon([(593, 438), (560, 420), (601, 420)], fill=1)
image = image.resize((96, 96), Image.Resampling.LANCZOS).convert('1')
(Path(__file__).resolve().parents[2] / 'src/xy/giteki-mask.bin').write_bytes(image.tobytes())
