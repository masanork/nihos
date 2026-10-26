#!/usr/bin/env python3
"""Build the real Zig renderer and export a PNG, animated GIF and HTML preview."""
import argparse
import base64
import ctypes
import io
from pathlib import Path
import subprocess
import sys

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", type=Path, default=ROOT / ".tools/zig-0.17.0/zig")
    parser.add_argument("--out", type=Path, default=ROOT / "build/boot-graphics")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    library = args.out.resolve() / ("preview.dylib" if sys.platform == "darwin" else "preview.so")
    subprocess.run([
        str(args.zig), "build-lib", "-dynamic", "-OReleaseSafe", "--dep", "boot_graphics",
        f"-Mroot={ROOT / 'tools/boot-graphics/preview.zig'}",
        f"-Mboot_graphics={ROOT / 'src/graphics/boot_graphics.zig'}",
        f"-femit-bin={library}",
    ], check=True)
    paint = ctypes.CDLL(str(library)).nih_boot_preview
    paint.argtypes = [ctypes.POINTER(ctypes.c_ubyte), ctypes.c_size_t, ctypes.c_ubyte, ctypes.c_ubyte]
    paint.restype = ctypes.c_bool
    pixels = (ctypes.c_ubyte * (720 * 1280 * 2))()

    def frame(progress, status):
        assert paint(pixels, len(pixels), progress, status)
        return Image.frombytes("RGB", (720, 1280), bytes(pixels), "raw", "BGR;16")

    first = frame(0, 1)
    middle = frame(128, 3)
    final = frame(255, 5)
    final.save(args.out / "ready.png")
    contact = Image.new("RGB", (1080, 640))
    for index, image in enumerate((first, middle, final)):
        contact.paste(image.resize((360, 640), Image.Resampling.LANCZOS), (index * 360, 0))
    contact.save(args.out / "preview.png")
    frames = [frame(round(i * 255 / 23), 1 if i < 8 else 3 if i < 23 else 5)
              .resize((360, 640), Image.Resampling.LANCZOS) for i in range(24)]
    frames[0].save(args.out / "preview.gif", save_all=True, append_images=frames[1:],
                   duration=[350] + [45] * 22 + [1800], loop=0)
    encoded = []
    for image in frames:
        buffer = io.BytesIO()
        image.save(buffer, format="PNG")
        encoded.append('"data:image/png;base64,' + base64.b64encode(buffer.getvalue()).decode() + '"')
    html = '''<!doctype html><html lang="ja"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>nihos — boot graphics</title><style>
body{margin:0;background:#202020;color:#ddd;font:15px system-ui;display:grid;place-items:center;min-height:100vh}
main{padding:24px;text-align:center}img{display:block;max-height:80vh;max-width:90vw;margin:auto;border:1px solid #333}
button{margin:18px;padding:9px 24px;background:#333;border:1px solid #555;color:#eee;cursor:pointer}
p{color:#aaa;font-size:12px}</style><main><img id="screen" alt="墨色から丹穂が朱色に染まるnihos起動画面">
<button id="replay">もう一度</button><p>描画のプレビュー・起動段階と時間は例示</p></main><script>
const frames=[FRAMES];let timer;function play(){clearTimeout(timer);let i=0;
function next(){document.querySelector('#screen').src=frames[i];if(i<frames.length-1){
timer=setTimeout(next,i++===0?350:45)}}next()}
document.querySelector('#replay').onclick=play;play();</script></html>'''
    (args.out / "preview.html").write_text(html.replace("FRAMES", ",".join(encoded)))
    print(args.out / "preview.html")
    print(args.out / "preview.png")


if __name__ == "__main__":
    main()
