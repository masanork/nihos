"""Check private JPEG fixture UART evidence and decode both images on the host."""
import argparse
import hashlib
import json
from pathlib import Path
import re


def fnv(data):
    value = 2166136261
    for byte in data:
        value = ((value ^ byte) * 16777619) & 0xffffffff
    return value


def parse(text):
    images, records, ended = {}, {}, set()
    done = False
    for line in text.splitlines():
        if 'NIHOS_JPEG_FAIL' in line or 'NIHOS_NATIVE_FAIL ' in line:
            raise ValueError('firmware reported failure')
        match = re.search(r'NIHOS_JPEG_(BEGIN|DATA|END) (.*)', line)
        if match:
            if done:
                raise ValueError('data after completion')
            tag, body = match.groups()
            fields = {key: int(value, 16) for key, value in re.findall(r'(\w+)=([0-9a-f]{8})(?=\s|$)', body)}
            if 'kind' not in fields:
                raise ValueError('image kind missing')
            kind = fields['kind']
            if tag == 'BEGIN':
                if not {'width', 'height', 'bytes', 'quality', 'source_fnv', 'encode_us'} <= fields.keys():
                    raise ValueError('image metadata missing')
                if kind != len(records) or kind not in (0, 1) or (kind == 1 and 0 not in ended):
                    raise ValueError('unexpected image order')
                if (fields['width'], fields['height'], fields['quality']) != (1280, 720, 75) or not 640 < fields['bytes'] <= 1843200 or not 0 < fields['encode_us'] < 5_000_000:
                    raise ValueError('invalid image geometry or timing')
                records[kind] = fields
                images[kind] = bytearray()
            elif tag == 'DATA':
                if kind not in images or kind in ended or fields.get('offset') != len(images[kind]) or ' data=' not in body:
                    raise ValueError('missing, repeated or post-completion bytes')
                data = bytes.fromhex(body.split(' data=', 1)[1])
                if not 0 < len(data) <= 96 or len(images[kind]) + len(data) > records[kind]['bytes']:
                    raise ValueError('invalid payload span')
                images[kind].extend(data)
            else:
                if kind not in records or kind in ended or not {'bytes', 'fnv'} <= fields.keys():
                    raise ValueError('unexpected image end')
                data = bytes(images[kind])
                if fields['bytes'] != len(data) or len(data) != records[kind]['bytes'] or fnv(data) != fields['fnv'] or not data.startswith(b'\xff\xd8') or not data.endswith(b'\xff\xd9'):
                    raise ValueError('image length, checksum or marker mismatch')
                ended.add(kind)
        if 'NIHOS_JPEG_DONE' in line:
            if done or ended != {0, 1}:
                raise ValueError('incomplete or duplicated completion')
            done = True
    if not done:
        raise ValueError('fixture did not complete')
    return records, {kind: bytes(data) for kind, data in images.items()}


def verify(directory):
    from PIL import Image
    records, images = parse((directory / 'serial.log').read_text())
    result = {}
    for kind, name in ((0, 'pattern.jpg'), (1, 'camera.jpg')):
        path = directory / name
        if path.read_bytes() != images[kind]:
            raise ValueError('saved image differs from captured bytes')
        with Image.open(path) as image:
            image.load()  # Force entropy decoding; parsing a header is insufficient.
            if image.size != (1280, 720) or image.mode != 'RGB':
                raise ValueError('decoded image format differs')
            if kind == 0:
                expected = [(248,0,0), (0,252,0), (0,0,248), (248,252,248),
                            (0,0,0), (0,252,248), (248,0,248), (248,252,0)]
                for band, color in enumerate(expected):
                    for y in (80, 360, 640):
                        pixel = image.getpixel((band * 160 + 80, y))
                        if any(abs(a-b) > 12 for a,b in zip(pixel, color)):
                            raise ValueError('known RGB565 bars decoded with wrong colors')
            result[name] = dict(records[kind], sha256=hashlib.sha256(images[kind]).hexdigest(),
                                decoded_mode=image.mode, decoded_size=list(image.size), extrema=image.getextrema())
    if records[0]['source_fnv'] == records[1]['source_fnv'] or images[0] == images[1]:
        raise ValueError('camera frame repeats the known pattern')
    colors = (0xf800, 0x07e0, 0x001f, 0xffff, 0, 0x07ff, 0xf81f, 0xffe0)
    pattern = b''.join(color.to_bytes(2, 'little') * 160 for color in colors) * 720
    if records[0]['source_fnv'] != fnv(pattern):
        raise ValueError('source pattern differs from expected RGB565 bytes')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.directory), indent=2))
