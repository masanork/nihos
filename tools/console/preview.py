#!/usr/bin/env python3
"""Render a log snapshot with the real Zig console raster; not device evidence."""
import argparse
import ctypes
from pathlib import Path
import subprocess
import sys
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--log', type=Path)
    parser.add_argument('--out', type=Path, default=ROOT / 'build/console-preview')
    parser.add_argument('--failed', action='store_true')
    parser.add_argument('--palette', choices=('neutral', 'green', 'blue', 'forest', 'matrix'), default='matrix')
    parser.add_argument('--font', choices=('basic', 'jetbrains', 'source-code', 'basic-light'), default='basic-light')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    library = args.out.resolve() / ('console.dylib' if sys.platform == 'darwin' else 'console.so')
    subprocess.run([str(ROOT / '.tools/zig-0.17.0/zig'), 'build-lib', '-dynamic', '-OReleaseSafe',
                    '--dep', 'text_console', f'-Mroot={ROOT / "tools/console/preview.zig"}',
                    f'-Mtext_console={ROOT / "src/console.zig"}', f'-femit-bin={library}'], check=True)
    log = args.log.read_bytes() if args.log else (
        b'NIHOS_NATIVE_BOOT backend=zig-sram rtos=none\n'
        b'CRT: bss=zero data=valid ecall=returned\n'
        b'PSRAM: 32 MiB, 200 MHz x16 DDR\n'
        b'DQS: phase=0 delay=17 repetitions=100\n'
        b'MEMORY: full sweep passed\n'
        b'DISPLAY: ST7121 1280x720 landscape 59.982 Hz target\n'
        b'CORES: SMP, timer, heap and IPI checks passed\n'
        b'CONSOLE: fixed ASCII raster initialized\n')
    pixels = (ctypes.c_ubyte * (720 * 1280 * 2))()
    render = ctypes.CDLL(str(library)).nih_console_preview
    render.argtypes = [ctypes.POINTER(ctypes.c_ubyte), ctypes.c_size_t, ctypes.c_char_p,
                       ctypes.c_size_t, ctypes.c_bool, ctypes.c_uint32, ctypes.c_uint32]
    render.restype = ctypes.c_bool
    assert render(pixels, len(pixels), log, len(log), args.failed, ('neutral', 'green', 'blue', 'forest', 'matrix').index(args.palette), ('basic', 'jetbrains', 'source-code', 'basic-light').index(args.font))
    image = Image.frombytes('RGB', (720, 1280), bytes(pixels), 'raw', 'BGR;16')
    destination = args.out / (('failed' if args.failed else 'console') + '-' + args.font + '-' + args.palette + '.png')
    image.transpose(Image.Transpose.ROTATE_270).save(destination)
    print(destination)

if __name__ == '__main__':
    main()
