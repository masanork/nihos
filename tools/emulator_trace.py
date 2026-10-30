#!/usr/bin/env python3
"""Record or compare deterministic RV32 input/frame traces."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

from canvas_live import Guest, OUT, ROOT

TRACE_SCHEMA = 'nihos-emulator-pointer-trace-v1'
REPORT_SCHEMA = 'nihos-emulator-trace-report-v1'
FIELDS = ('samples', 'events', 'clicks', 'kind', 'pixel_sha256')


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def validate_trace(trace):
    if not isinstance(trace, dict) or set(trace) != {'schema', 'name', 'samples'} or trace['schema'] != TRACE_SCHEMA:
        raise ValueError('invalid trace schema')
    if not isinstance(trace['name'], str) or not 1 <= len(trace['name']) <= 80:
        raise ValueError('invalid trace name')
    samples = trace['samples']
    if not isinstance(samples, list) or not 1 <= len(samples) <= 256:
        raise ValueError('invalid trace sample count')
    previous = 0
    for sample in samples:
        if not isinstance(sample, dict) or set(sample) != {'contacts', 'x', 'y', 'time_us'} or any(type(sample[k]) is not int for k in sample):
            raise ValueError('invalid trace sample')
        if sample['contacts'] not in (0, 1, 2) or not 0 <= sample['x'] < 720 or not 0 <= sample['y'] < 1280 or not previous <= sample['time_us'] <= 0xffffffff:
            raise ValueError('trace sample out of range or out of order')
        previous = sample['time_us']
    return digest(canonical(trace))


def validate_report(report):
    if not isinstance(report, dict) or report.get('schema') != REPORT_SCHEMA or report.get('evidence') != 'esp32p4-emulator-rv32':
        raise ValueError('invalid report schema or evidence')
    trace = report.get('trace')
    trace_hash = validate_trace(trace)
    if report.get('trace_sha256') != trace_hash:
        raise ValueError('trace digest mismatch')
    frames = report.get('frames')
    if not isinstance(frames, list) or len(frames) != len(trace['samples']) + 1:
        raise ValueError('incomplete frame sequence')
    for index, frame in enumerate(frames):
        if not isinstance(frame, dict) or set(frame) != set(FIELDS):
            raise ValueError('invalid frame record')
        if any(type(frame[k]) is not int or frame[k] < 0 for k in FIELDS[:-1]) or frame['samples'] != index:
            raise ValueError('invalid frame counters')
        if not isinstance(frame['pixel_sha256'], str) or not re.fullmatch('[0-9a-f]{64}', frame['pixel_sha256']):
            raise ValueError('invalid frame digest')
    identity = report.get('identity')
    if not isinstance(identity, dict) or any(not isinstance(identity.get(k), str) or not re.fullmatch('[0-9a-f]{64}', identity[k]) for k in ('image_sha256', 'elf_sha256', 'flash_sha256', 'source_sha256')):
        raise ValueError('invalid artifact identity')
    return trace_hash


def compare(expected, actual):
    if validate_report(expected) != validate_report(actual):
        raise ValueError('reports use different traces')
    for index, (left, right) in enumerate(zip(expected['frames'], actual['frames'])):
        if left != right:
            raise ValueError(f'frame {index} differs: ' + ', '.join(key for key in FIELDS if left[key] != right[key]))
    return len(expected['frames'])


def source_identity():
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT).strip()
    diff = subprocess.check_output(['git', 'diff', '--binary', 'HEAD'], cwd=ROOT)
    names = subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard', '-z'], cwd=ROOT).split(b'\0')
    extras = []
    for raw in sorted(filter(None, names)):
        path = ROOT / raw.decode()
        if path.is_symlink() or not path.is_file():
            raise ValueError('unsupported untracked source entry')
        extras.append((raw.decode(), digest(path.read_bytes())))
    return {'head': head.decode(), 'source_sha256': digest(head + b'\0' + diff + b'\0' + canonical(extras))}


def record(trace):
    trace_hash = validate_trace(trace)
    before = source_identity()
    guest = Guest()
    try:
        frames = [{k: guest.state[k] for k in FIELDS}]
        for sample in trace['samples']:
            state = guest.sample(**sample)
            frames.append({k: state[k] for k in FIELDS})
        identity = dict(before)
        for field, name in (('image_sha256', 'nihos-native.bin'), ('elf_sha256', 'nihos-native.elf'), ('flash_sha256', 'nihos-native-flash.bin')):
            identity[field] = digest((OUT / name).read_bytes())
        if source_identity() != before:
            raise RuntimeError('source changed while recording')
        report = {'schema': REPORT_SCHEMA, 'evidence': 'esp32p4-emulator-rv32', 'trace': trace,
                  'trace_sha256': trace_hash, 'frames': frames, 'identity': identity}
        validate_report(report)
        return report
    finally:
        guest.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    capture = sub.add_parser('record')
    capture.add_argument('trace', type=Path)
    capture.add_argument('output', type=Path)
    check = sub.add_parser('compare')
    check.add_argument('expected', type=Path)
    check.add_argument('actual', type=Path)
    args = parser.parse_args()
    if args.action == 'record':
        if args.output.exists():
            parser.error('output already exists')
        trace = json.loads(args.trace.read_text())
        result = record(trace)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open('x') as out:
            json.dump(result, out, indent=2)
            out.write('\n')
        print(f'Recorded {len(result["frames"])} emulated RV32 frames in {args.output}')
    else:
        count = compare(json.loads(args.expected.read_text()), json.loads(args.actual.read_text()))
        print(f'{count} emulated RV32 frames and input states match')


if __name__ == '__main__':
    main()
