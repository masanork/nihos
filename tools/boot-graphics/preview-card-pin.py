#!/usr/bin/env python3
"""Render the real Zig PIN prompt as PNGs/HTML; never opens a card or takes a PIN."""
import argparse
import base64
import ctypes
from pathlib import Path
import subprocess
import sys
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=ROOT / "build/card-pin")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    library = args.out.resolve() / ("preview.dylib" if sys.platform == "darwin" else "preview.so")
    subprocess.run([str(ROOT / ".tools/zig-0.17.0/zig"), "build-lib", "-dynamic", "-OReleaseSafe",
                    str(ROOT / "src/card_pin_preview.zig"), f"-femit-bin={library}"], check=True)
    paint = ctypes.CDLL(str(library)).nih_card_pin_preview
    paint.argtypes = [ctypes.POINTER(ctypes.c_ubyte), ctypes.c_size_t, ctypes.c_ubyte, ctypes.c_bool]
    paint.restype = ctypes.c_bool
    pixels = (ctypes.c_ubyte * (720 * 1280 * 2))()
    images = []
    for index in range(6):
        active = index < 5
        count = index if active else 0
        assert paint(pixels, len(pixels), count, active)
        image = Image.frombytes("RGB", (720, 1280), bytes(pixels), "raw", "BGR;16")
        path = args.out / f"{'pin-' + str(count) if active else 'disabled'}.png"
        image.save(path)
        images.append("data:image/png;base64," + base64.b64encode(path.read_bytes()).decode())
    import json
    html = '''<!doctype html><html lang="ja"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>nihos PIN画面・ホストプレビュー</title><style>body{margin:0;background:#242424;color:#ddd;font:15px system-ui;text-align:center}main{padding:20px}img{display:block;max-height:80vh;max-width:95vw;margin:18px auto}select{font:inherit;padding:8px}p{font-size:13px}</style>
<main><select id="state" aria-label="入力桁数の表示例"><option value="0">0桁</option><option value="1">1桁</option><option value="2" selected>2桁</option><option value="3">3桁</option><option value="4">4桁</option><option value="5">入力無効</option></select>
<img id="screen" alt="入力補助用暗証番号の画面"><p>ホスト描画の例。残り回数は表示例です。カードやPIN入力には接続しません。</p></main>
<script>const images=IMAGES;const state=document.querySelector('#state');function show(){document.querySelector('#screen').src=images[Number(state.value)]}state.onchange=show;show();</script></html>'''
    (args.out / "preview.html").write_text(html.replace("IMAGES", json.dumps(images)))
    print(args.out / "preview.html")


if __name__ == "__main__":
    main()
