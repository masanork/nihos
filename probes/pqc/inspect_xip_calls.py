#!/usr/bin/env python3
"""Report statically annotated branches into PQC Flash; not a call-graph proof."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

LABEL = re.compile(r'^([0-9a-f]+) <(.+)>:$')
BRANCH = re.compile(r'^\s*([0-9a-f]+):\s+[0-9a-f]+\s+(jal|jalr|j)\s+(.+)$')
TARGET = re.compile(r'(?:#\s*)?([0-9a-f]{8})\s+<([^>]+)>')

def inspect(disassembly, start, end):
    current = None
    incoming = []
    unknown_indirect = []
    for line in disassembly.splitlines():
        label = LABEL.match(line.strip())
        if label:
            current = label[2]
            continue
        branch = BRANCH.match(line)
        if not branch:
            continue
        pc, op, operand = int(branch[1], 16), branch[2], branch[3]
        target = TARGET.search(operand)
        if op == 'jalr' and not target:
            unknown_indirect.append({'caller': current, 'pc': hex(pc), 'operand': operand.strip()})
        if target:
            destination = int(target[1], 16)
            if not start <= pc < end and start <= destination < end:
                incoming.append({'caller': current, 'pc': hex(pc), 'target': target[2], 'address': hex(destination)})
    return {'incoming_annotated_branches': incoming, 'unresolved_indirect_jalr': unknown_indirect}

def main():
    if len(sys.argv) != 5:
        raise SystemExit('usage: inspect_xip_calls.py OBJDUMP ELF IMAGE_AUDIT OUTPUT.json')
    tool, elf, audit_path, output = sys.argv[1:]
    audit = json.loads(Path(audit_path).read_text())
    if hashlib.sha256(Path(elf).read_bytes()).hexdigest() != audit['elf_sha256']:
        raise ValueError('ELF does not match image audit')
    span = audit['pqc_fixture']
    disasm = subprocess.check_output([tool, '-d', elf], text=True)
    result = inspect(disasm, int(span['text_start'], 16), int(span['text_end'], 16))
    result['elf_sha256'] = audit['elf_sha256']
    result['limitation'] = 'Indirect targets, relocations without annotations and runtime control flow are not proven.'
    Path(output).write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))

if __name__ == '__main__': main()
