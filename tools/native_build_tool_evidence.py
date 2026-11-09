#!/usr/bin/env python3
"""Capture bounded observations of tools selected for a native CI build."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

IDF_COMMIT = '296b6eab9445fd720e71aecab961e2d3fbca9944'  # ESP-IDF v5.4.4 peeled tag


def validate(data):
    if (not isinstance(data, dict) or set(data) != {'schema', 'zig_version', 'zig_sha256', 'idf_commit', 'idf_tracked_clean'} or
            type(data['schema']) is not int or data['schema'] != 1 or data['zig_version'] != '0.17.0' or
            not isinstance(data['zig_sha256'], str) or not re.fullmatch(r'[0-9a-f]{64}', data['zig_sha256']) or
            data['idf_commit'] != IDF_COMMIT or data['idf_tracked_clean'] is not True):
        raise ValueError('invalid or unapproved native build tool evidence')
    return data


def observe(zig, idf):
    version = subprocess.check_output([str(zig), 'version'], text=True).strip()
    commit = subprocess.check_output(['git', '-C', str(idf), 'rev-parse', 'HEAD'], text=True).strip()
    status = subprocess.check_output(['git', '-C', str(idf), 'status', '--porcelain', '--untracked-files=no', '--ignore-submodules=all'], text=True)
    return validate({'schema': 1, 'zig_version': version,
                     'zig_sha256': hashlib.sha256(zig.read_bytes()).hexdigest(),
                     'idf_commit': commit, 'idf_tracked_clean': not bool(status)})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['capture', 'check'])
    parser.add_argument('--zig', type=Path, required=True)
    parser.add_argument('--idf', type=Path, required=True)
    parser.add_argument('--receipt', type=Path, required=True)
    args = parser.parse_args()
    current = observe(args.zig, args.idf)
    if args.action == 'capture':
        args.receipt.write_text(json.dumps(current, sort_keys=True, separators=(',', ':')) + '\n')
    elif validate(json.loads(args.receipt.read_text())) != current:
        raise SystemExit('native build tool evidence changed during build')


if __name__ == '__main__':
    main()
