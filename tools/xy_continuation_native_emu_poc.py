#!/usr/bin/env python3
"""Prepare an isolated emulator crate containing the native continuation probe."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
ROOT=Path(__file__).resolve().parents[1]
def prepare(dst):
    dst=dst.resolve()
    if dst.exists() and any(dst.iterdir()): raise ValueError('destination must be empty')
    shutil.copytree(ROOT/'apps/xy-gpui',dst,ignore=shutil.ignore_patterns('target'))
    module=dst/'src/emu/mod.rs';text=module.read_text();pos=text.rfind('\n}')
    if pos<0 or text[pos:].strip()!='}': raise ValueError('test module closing brace changed')
    fixture=(ROOT/'tools/xy_continuation_native_emu_poc.rs.inc').read_text()
    module.write_text(text[:pos]+'\n'+fixture+text[pos:])
    return {'scope':'temporary emulator test crate; no product change','fixture_sha256':hashlib.sha256(fixture.encode()).hexdigest(),'module_sha256':hashlib.sha256(module.read_bytes()).hexdigest(),'crate':str(dst)}
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--destination',type=Path,required=True);a=p.parse_args();print(json.dumps(prepare(a.destination),indent=2))
