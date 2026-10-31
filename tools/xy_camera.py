"""Bounded XY camera qualification inside an already verified serial lease.

This collector does not flash or claim serial ownership. Its caller must freeze,
verify, back up and restore the candidate under exclusive board/serial access.
Actual scene bytes stay in the caller's private output directory.
"""
import hashlib
import json
import re
import time


def fnv(data):
    value = 2166136261
    for byte in data:
        value = ((value ^ byte) * 16777619) & 0xffffffff
    return value


def reply_bytes(line):
    match = re.fullmatch(rb'NIHOS_NATIVE_XY_REPLY data=([0-9a-f]*)', line)
    if not match or len(match[1]) > 256 or len(match[1]) % 2:
        raise ValueError('invalid XY reply')
    return bytes.fromhex(match[1].decode())


def jpeg_chunk(reply, count):
    if not 0 <= count <= 32 or not re.fullmatch(rb'"[0-9a-f]*"', reply) or len(reply) != count * 2 + 2:
        raise ValueError('invalid Scheme camera/read result')
    return bytes.fromhex(reply[1:-1].decode())


def capture(port, output):
    import esptool
    port.timeout = .1
    port.reset_input_buffer()
    chip = esptool.detect_chip(port=port, baud=115200)
    if (chip.get_chip_description(), bytes(chip.read_mac()).hex()) != ('ESP32-P4 (revision v1.3)', 'e8f60ae2e89c'):
        raise ValueError('device identity differs')
    chip.watchdog_reset()
    port.close(); port.open()  # Caller reacquires kernel exclusion on reopen.
    pending = bytearray()
    state = None
    ready = None
    notes = b'camera-notes'
    controls = []
    started = time.monotonic()
    with (output / 'serial.log').open('wb') as log:
        def line(deadline):
            nonlocal pending, state, ready
            while b'\n' not in pending:
                if time.monotonic() - started > 360:
                    raise TimeoutError('overall XY capture exceeded six minutes')
                if time.monotonic() > deadline:
                    raise TimeoutError('bounded XY phase deadline expired')
                data = port.read(max(1, port.in_waiting))
                pending.extend(data); log.write(data); log.flush()
            value, _, pending = pending.partition(b'\n')
            value = bytes(value).rstrip(b'\r')
            if b'NIHOS_NATIVE_FAIL' in value or b'NIHOS_JPEG_FAIL' in value:
                raise ValueError('firmware failed')
            fields = {k.decode(): int(v, 16) for k,v in re.findall(rb'(\w+)=([0-9a-f]{8})(?=\s|$)',value)}
            if value.startswith(b'NIHOS_NATIVE_XY_STATE '):
                state = fields
            if value.startswith(b'NIHOS_XY_JPEG_READY '):
                if ready is not None:
                    raise ValueError('duplicate camera completion')
                ready = fields
            return value
        def wait(predicate):
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                value = line(deadline)
                if predicate(value): return value
            raise TimeoutError('XY request did not complete')
        def unchanged():
            if not state or (state['bytes'], state['cursor'], state['fnv']) != (len(notes), len(notes), fnv(notes)):
                raise ValueError('camera operation changed the document')
        def evaluate(source, expected=None, error=False):
            port.write(b'\x1b'); port.flush()
            wait(lambda value: value.startswith(b'NIHOS_NATIVE_XY_STATE ') and state['mode'] == 1)
            port.write(source + b'\r'); port.flush()
            result = reply_bytes(wait(lambda value: value.startswith(b'NIHOS_NATIVE_XY_REPLY ')))
            unchanged()
            if state['mode'] != 0 or state['status'] not in ((5,6) if error is None else (6,) if error else (5,)):
                raise ValueError('Scheme result/error state differs')
            if expected is not None and result != expected:
                raise ValueError('unexpected Scheme response to ' + source.decode())
            return result
        wait(lambda value: value.startswith(b'NIHOS_NATIVE_XY_READY '))
        wait(lambda value: value.startswith(b'NIHOS_NATIVE_XY_STATE ') and state['mode'] == 0)
        port.write(notes); port.flush()
        wait(lambda value: value.startswith(b'NIHOS_NATIVE_XY_STATE ') and state['bytes'] == len(notes))
        # The previous fixture auto-started at ten seconds. This profile stays
        # idle until an explicit Scheme capture command, even after that time.
        idle_end = time.monotonic() + 11
        while time.monotonic() < idle_end:
            if ready is not None: raise ValueError('camera started without a request')
            data = port.read(max(1, port.in_waiting))
            pending.extend(data); log.write(data); log.flush()
        evaluate(b'(camera/info 1)', b'Invalid camera handle', error=True)
        controls.append('unissued-handle')
        evaluate(b'(define image (camera/capture!)) image', b'1')
        evaluate(b'(camera/capture!)', b'Camera busy', error=True)
        controls.append('second-capture-busy')
        observed = evaluate(b'(camera/info image)')
        if observed == b'(pending 1280 720 0)':
            result = evaluate(b'(camera/read image 0 1)', error=None)
            if result == b'Camera busy': controls.append('pending-read-busy')
            elif jpeg_chunk(result,1) != b'\xff': raise ValueError('unexpected first camera byte')
        if ready is None: wait(lambda value: value.startswith(b'NIHOS_XY_JPEG_READY '))
        if (ready['handle'],ready['width'],ready['height']) != (1,1280,720) or not 640 < ready['bytes'] <= 1843200 or not 0 < ready['encode_us'] < 5_000_000:
            raise ValueError('invalid JPEG metadata')
        evaluate(b'(camera/info image)', f"(ready 1280 720 {ready['bytes']})".encode())
        for source, expected in [(b'(camera/info 2)',b'Invalid camera handle'),(b'(camera/read image -1 1)',b'Invalid camera range'),(b'(camera/read image 0 33)',b'Invalid camera range'),(f"(camera/read image {ready['bytes']} 1)".encode(),b'Invalid camera range')]:
            evaluate(source, expected, error=True); controls.append(source.decode())
        data = bytearray()
        while len(data) < ready['bytes']:
            count = min(32, ready['bytes'] - len(data))
            result = evaluate(f'(camera/read image {len(data)} {count})'.encode())
            data.extend(jpeg_chunk(result, count))
            if len(data) % 4096 == 0: print(f'XY_JPEG_READ {len(data)}/{ready["bytes"]}',flush=True)
        evaluate(f"(camera/read image {ready['bytes']} 0)".encode(), b'""')
        if fnv(data) != ready['fnv'] or not data.startswith(b'\xff\xd8') or not data.endswith(b'\xff\xd9'):
            raise ValueError('Scheme-reconstructed JPEG differs from completed codec bytes')
        path = output / 'camera.jpg'; path.write_bytes(data)
        port.write(b'!');port.flush()
        wait(lambda value: value.startswith(b'NIHOS_NATIVE_XY_STATE ') and state['bytes']==len(notes)+1)
        port.write(b'\x1a');port.flush()
        wait(lambda value: value.startswith(b'NIHOS_NATIVE_XY_STATE ') and state['bytes']==len(notes))
        unchanged()
        evaluate(b'(camera/capture!)', b'Camera busy', error=True)
        result = dict(ready, jpeg_sha256=hashlib.sha256(data).hexdigest(), controls=controls, document_preserved=True, edit_undo_after_read=True, elapsed_seconds=time.monotonic()-started)
        (output/'xy-camera.json').write_text(json.dumps(result,indent=2)+'\n')
        print('XY_JPEG_TRANSFERRED', len(data),flush=True)
        return result


def reconstruct(text):
    metadata = None
    reading = False
    data = bytearray()
    revision = None
    replied_revision = None
    for line in text.splitlines():
        if b'NIHOS_NATIVE_FAIL' in line or b'NIHOS_JPEG_FAIL' in line:
            raise ValueError('firmware failed')
        if line.startswith(b'NIHOS_NATIVE_XY_STATE '):
            fields = {k.decode():int(v,16) for k,v in re.findall(rb'(\w+)=([0-9a-f]{8})(?=\s|$)',line)}
            revision = fields['revision']
        if line.startswith(b'NIHOS_XY_JPEG_READY '):
            if metadata is not None: raise ValueError('duplicate completion')
            metadata = {k.decode():int(v,16) for k,v in re.findall(rb'(\w+)=([0-9a-f]{8})(?=\s|$)',line)}
            if not {'handle','bytes','width','height','source_fnv','encode_us','fnv'} <= metadata.keys(): raise ValueError('incomplete metadata')
            if (metadata['handle'],metadata['width'],metadata['height']) != (1,1280,720) or not 640 < metadata['bytes'] <= 1843200 or not 0 < metadata['encode_us'] < 5_000_000: raise ValueError('invalid metadata')
        if not line.startswith(b'NIHOS_NATIVE_XY_REPLY '): continue
        reply = reply_bytes(line)
        if revision is None: raise ValueError('Scheme reply has no state revision')
        if revision == replied_revision: continue
        replied_revision = revision
        if metadata and reply == f"(ready 1280 720 {metadata['bytes']})".encode():
            if reading: raise ValueError('repeated read session')
            reading = True;continue
        if not reading or not re.fullmatch(rb'"[0-9a-f]*"',reply): continue
        count = (len(reply)-2)//2
        data.extend(jpeg_chunk(reply,count))
        if len(data) > metadata['bytes']: raise ValueError('too many bytes')
    if not reading or len(data) != metadata['bytes'] or fnv(data) != metadata['fnv']:
        raise ValueError('incomplete or corrupted Scheme transfer')
    if not data.startswith(b'\xff\xd8') or not data.endswith(b'\xff\xd9'): raise ValueError('invalid JPEG markers')
    return metadata, bytes(data)


def verify(directory):
    from PIL import Image
    metadata, data = reconstruct((directory/'serial.log').read_bytes())
    path=directory/'camera.jpg'
    if path.read_bytes() != data: raise ValueError('saved JPEG differs from Scheme replies')
    with Image.open(path) as image:
        image.load()
        if image.size != (1280,720) or image.mode != 'RGB': raise ValueError('decoded geometry/mode differs')
    return dict(metadata,jpeg_sha256=hashlib.sha256(data).hexdigest(),decoded_size=[1280,720],decoded_mode='RGB')


if __name__ == '__main__':
    import argparse
    from pathlib import Path
    parser=argparse.ArgumentParser(description='Reconstruct and fully decode private XY JPEG evidence')
    parser.add_argument('directory',type=Path)
    args=parser.parse_args()
    print(json.dumps(verify(args.directory),indent=2))
