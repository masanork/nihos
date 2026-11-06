#!/usr/bin/env python3
"""Report statically named trap edges, not a complete IRQ/cache-off proof."""
import bisect
import json
import re
import subprocess
import sys

if len(sys.argv) != 4:
    raise SystemExit('usage: inspect-irq-edges.py OBJDUMP ELF OUTPUT.json')
objdump, elf, output = sys.argv[1:]
text = subprocess.check_output([objdump, '-d', '--no-show-raw-insn', elf], text=True)
header = re.compile(r'^([0-9a-fA-F]+) <(.+)>:$')
insn = re.compile(r'^\s*([0-9a-fA-F]+):\s+([a-zA-Z0-9_.]+)\s*(.*)$')
target = re.compile(r'(?:^|\s|#)([0-9a-fA-F]+)\s+<([^>]+)>')
functions = {}
current = None
for line in text.splitlines():
    m = header.match(line)
    if m:
        current = int(m[1], 16)
        functions.setdefault(current, {'name': m[2], 'insns': []})
        continue
    m = insn.match(line)
    if m and current is not None:
        functions[current]['insns'].append((int(m[1], 16), m[2], m[3]))
starts = sorted(functions)
names = {value['name']: key for key, value in functions.items()}
roots = ['nih_native_trap', 'nih_native_dispatch']
if not all(name in names for name in roots):
    raise SystemExit('missing trap/dispatcher root in disassembly')
edges = {start: set() for start in starts}
indirect = {start: [] for start in starts}
for start, function in functions.items():
    previous = None
    for pc, op, operands in function['insns']:
        if op in ('jalr', 'jr'):
            resolved = False
            # Resolve only the canonical adjacent AUIPC/JALR call sequence.
            match = re.match(r'^(?:ra,)?(-?(?:0x[0-9a-fA-F]+|[0-9]+))\((\w+)\)', operands)
            if op == 'jalr' and match and previous and previous[1] == 'auipc':
                upper = re.match(r'^(\w+),\s*(0x[0-9a-fA-F]+|[0-9]+)', previous[2])
                if upper and upper[1] == match[2] and previous[0]+4 == pc:
                    address = (previous[0] + (int(upper[2], 0) << 12) + int(match[1], 0)) & 0xffffffff
                    if address in functions:
                        edges[start].add(address)
                        resolved = True
            if not resolved:
                indirect[start].append({'pc': hex(pc), 'op': op, 'operands': operands})
        elif op in ('j', 'jal', 'beq', 'bne', 'blt', 'bge', 'bltu', 'bgeu', 'beqz', 'bnez', 'bltz', 'bgez', 'bgtz', 'blez'):
            m = target.search(operands)
            if m:
                address = int(m[1], 16)
                index = bisect.bisect_right(starts, address)-1
                if index >= 0 and starts[index] != start and starts[index] == address:
                    edges[start].add(address)
        previous = (pc, op, operands)
seen = set()
queue = [names[name] for name in roots]
while queue:
    current = queue.pop()
    if current in seen: continue
    seen.add(current)
    queue.extend(edges.get(current, ()))
selected = [functions[start]['name'] for start in seen if re.match(r'(?:ssh(?:_|\.)|crypto\.|vt100\.)', functions[start]['name'])]
unresolved = [{'function': functions[start]['name'], **call} for start in sorted(seen) for call in indirect[start]]
result = {'roots': roots, 'directly_reachable_functions': len(seen), 'directly_reachable_ssh_crypto_names': sorted(selected),
          'unresolved_indirect_count': len(unresolved), 'unresolved_indirect_sites': unresolved,
          'limitations': 'Named direct and adjacent AUIPC/JALR edges only; other indirect calls, jumps, interrupt variants and cache-off reachability are not proven.'}
with open(output, 'w') as f:
    json.dump(result, f, indent=2)
    f.write('\n')
print(json.dumps({k: v for k, v in result.items() if k != 'unresolved_indirect_sites'}, sort_keys=True))
