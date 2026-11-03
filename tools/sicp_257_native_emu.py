#!/usr/bin/env python3
"""Prepare a disposable RV32 emulator crate for the MIT 2.57 input journey."""
import argparse
import hashlib
import json
from pathlib import Path

import sicp_mceval_original_syntax as syntax
import sicp_symbolic_deriv_2_57 as deriv
import xy_continuation_native_emu_poc as native

ROOT = Path(__file__).resolve().parents[1]


def prepare(destination):
    result = native.prepare(destination)
    module = destination / 'src/emu/mod.rs'
    source = ' '.join(' '.join(form.split()) for form in syntax.split_forms(deriv.original_setup()))
    if len(source) != 1408:
        raise ValueError('unexpected compact source length')
    (destination / 'src/emu/sicp_257_input.scm').write_text(source)
    text = module.read_text()
    position = text.rfind('\n}')
    fixture = (ROOT / 'tools/sicp_257_native_emu.rs.inc').read_text()
    if position < 0 or text[position:].strip() != '}':
        raise ValueError('test module closing brace changed')
    module.write_text(text[:position] + '\n' + fixture + text[position:])
    result.update(scheme_bytes=len(source), scheme_sha256=hashlib.sha256(source.encode()).hexdigest(),
                  fixture_sha256=hashlib.sha256(fixture.encode()).hexdigest(),
                  module_sha256=hashlib.sha256(module.read_bytes()).hexdigest())
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--destination', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.destination), indent=2))
