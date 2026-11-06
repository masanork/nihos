#!/usr/bin/env python3
"""Report statically named trap edges, not a complete IRQ/cache-off proof."""
import argparse
import bisect
import json
import re
import subprocess
from pathlib import Path

HEADER = re.compile(r'^([0-9a-fA-F]+) <(.+)>:$')
INSN = re.compile(r'^\s*([0-9a-fA-F]+):\s+([a-zA-Z0-9_.]+)\s*(.*)$')
TARGET = re.compile(r'(?:^|\s|#)([0-9a-fA-F]+)\s+<([^>]+)>')
INDIRECT_OFFSET = re.compile(r'^(?:ra,)?(-?(?:0x[0-9a-fA-F]+|[0-9]+))\((\w+)\)')
AUIPC = re.compile(r'^(\w+),\s*(0x[0-9a-fA-F]+|[0-9]+)')
BRANCHES = {'j', 'jal', 'beq', 'bne', 'blt', 'bge', 'bltu', 'bgeu',
            'beqz', 'bnez', 'bltz', 'bgez', 'bgtz', 'blez'}


def analyze(text, roots=('nih_native_trap', 'nih_native_dispatch'), placed_addresses=None):
    functions = {}
    current = None
    for line in text.splitlines():
        m = HEADER.match(line)
        if m:
            current = int(m[1], 16)
            functions.setdefault(current, {'name': m[2], 'insns': []})
            continue
        m = INSN.match(line)
        if m and current is not None:
            functions[current]['insns'].append((int(m[1], 16), m[2], m[3]))
    starts = sorted(functions)
    names = {value['name']: key for key, value in functions.items()}
    if not all(name in names for name in roots):
        raise ValueError('missing trap/dispatcher root in disassembly')
    edges = {start: set() for start in starts}
    indirect = {start: [] for start in starts}
    for start, function in functions.items():
        previous = None
        for pc, op, operands in function['insns']:
            if op in ('jalr', 'jr'):
                resolved = False
                # A contiguous AUIPC/JALR or AUIPC/JR pair with the same
                # register is PC-relative. Never infer dynamic register calls.
                match = INDIRECT_OFFSET.match(operands)
                if match and previous and previous[1] == 'auipc':
                    upper = AUIPC.match(previous[2])
                    if upper and upper[1] == match[2] and previous[0] + 4 == pc:
                        address = (previous[0] + (int(upper[2], 0) << 12) + int(match[1], 0)) & 0xffffffff
                        if address in functions:
                            edges[start].add(address)
                            resolved = True
                if not resolved:
                    indirect[start].append({'pc': hex(pc), 'op': op, 'operands': operands})
            elif op in BRANCHES:
                m = TARGET.search(operands)
                if m:
                    address = int(m[1], 16)
                    index = bisect.bisect_right(starts, address) - 1
                    if index >= 0 and starts[index] != start and starts[index] == address:
                        edges[start].add(address)
            previous = (pc, op, operands)
    seen = set()
    queue = [names[name] for name in roots]
    while queue:
        current = queue.pop()
        if current in seen:
            continue
        seen.add(current)
        queue.extend(edges.get(current, ()))
    selected = [functions[start]['name'] for start in seen if re.match(r'(?:ssh(?:_|\.)|crypto\.|vt100\.)', functions[start]['name'])]
    unresolved = [{'function': functions[start]['name'], **call} for start in sorted(seen) for call in indirect[start]]
    placed_addresses = placed_addresses or {}
    placed_reachable = [{'address': hex(start), 'symbols': placed_addresses[start]} for start in sorted(seen) if start in placed_addresses]
    return {'roots': list(roots), 'directly_reachable_placed_functions': placed_reachable, 'directly_reachable_functions': len(seen), 'directly_reachable_ssh_crypto_names': sorted(selected),
            'unresolved_indirect_count': len(unresolved), 'unresolved_indirect_sites': unresolved,
            'limitations': 'Named direct and adjacent AUIPC/JALR or AUIPC/JR edges only; other indirect calls, jumps, interrupt variants and cache-off reachability are not proven.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('objdump')
    parser.add_argument('elf')
    parser.add_argument('output')
    args = parser.parse_args()
    text = subprocess.check_output([args.objdump, '-d', '--no-show-raw-insn', args.elf], text=True)
    table = subprocess.check_output([args.objdump, '-t', args.elf], text=True)
    expected = set(json.loads(Path(__file__).with_name('expected-functions.json').read_text()))
    placed = {}
    found = set()
    for line in table.splitlines():
        fields = line.split(maxsplit=5)
        if len(fields) != 6 or fields[2] != 'F' or fields[5] not in expected:
            continue
        address = int(fields[0], 16)
        placed.setdefault(address, []).append(fields[5])
        found.add(fields[5])
    if found != expected:
        raise ValueError('exact placement symbols missing from objdump symbol table')
    result = analyze(text, placed_addresses=placed)
    with open(args.output, 'w') as f:
        json.dump(result, f, indent=2)
        f.write('\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'unresolved_indirect_sites'}, sort_keys=True))


if __name__ == '__main__':
    main()
