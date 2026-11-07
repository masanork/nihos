#!/usr/bin/env python3
"""Report statically named trap edges, not a complete IRQ/cache-off proof."""
import argparse
import bisect
from collections import deque
import json
import re
import subprocess
import struct
from pathlib import Path

HEADER = re.compile(r'^([0-9a-fA-F]+) <(.+)>:$')
INSN = re.compile(r'^\s*([0-9a-fA-F]+):\s+([a-zA-Z0-9_.]+)\s*(.*)$')
TARGET = re.compile(r'(?:^|\s|#)([0-9a-fA-F]+)\s+<([^>]+)>')
INDIRECT_OFFSET = re.compile(r'^(?:ra,)?(-?(?:0x[0-9a-fA-F]+|[0-9]+))\((\w+)\)')
AUIPC = re.compile(r'^(\w+),\s*(0x[0-9a-fA-F]+|[0-9]+)')
BRANCHES = {'j', 'jal', 'beq', 'bne', 'blt', 'bge', 'bltu', 'bgeu',
            'beqz', 'bnez', 'bltz', 'bgez', 'bgtz', 'blez'}


def readonly_elf_reader(path):
    elf = Path(path).read_bytes()
    header = struct.unpack_from('<16sHHIIIIIHHHHHH', elf)
    if header[0][:6] != b'\x7fELF\x01\x01' or header[11] != 40:
        raise ValueError('expected little-endian ELF32')
    sections = [struct.unpack_from('<10I', elf, header[6] + i * header[11]) for i in range(header[12])]

    def read_words(address, count):
        if count < 1 or count > 256 or address % 4:
            return None
        matches = [sec for sec in sections if sec[1] != 8 and sec[2] & 2 and not sec[2] & 1 and
                   sec[3] <= address and address + 4 * count <= sec[3] + sec[5]]
        if len(matches) != 1:
            return None
        sec = matches[0]
        offset = sec[4] + address - sec[3]
        if offset + 4 * count > len(elf):
            return None
        return struct.unpack_from('<' + 'I' * count, elf, offset)
    return read_words


def internal_jump_table(insns, idx, read_words, branch_edges):
    """Recognize one guarded compiler switch; return None on any ambiguity."""
    if read_words is None or insns[idx][1] != 'jr':
        return None
    pc, _, operands = insns[idx]
    jump_reg = operands.split('#', 1)[0].strip()
    if not re.fullmatch(r'\w+', jump_reg):
        return None
    # Require contiguous slli/lui/addi/add/lw and bounded harmless setup.
    for sh in range(max(0, idx - 10), idx - 4):
        seq = insns[sh:sh + 5]
        if [item[1] for item in seq] != ['slli', 'lui', 'addi', 'add', 'lw']:
            continue
        args = [item[2].split('#', 1)[0].replace(' ', '') for item in seq]
        shift = re.fullmatch(r'(\w+),(\w+),(?:0x2|2)', args[0])
        base = re.fullmatch(r'(\w+),(0x[0-9a-fA-F]+|[0-9]+)', args[1])
        if not shift or not base or shift[1] == base[1]:
            continue
        if any(right[0] - left[0] not in (2, 4) for left, right in zip(seq, seq[1:])):
            continue
        adj = re.fullmatch(r'(\w+),(\w+),(-?(?:0x[0-9a-fA-F]+|[0-9]+))', args[2])
        add = re.fullmatch(r'(\w+),(\w+),(\w+)', args[3])
        load = re.fullmatch(r'(\w+),0\((\w+)\)', args[4])
        if not adj or not add or not load or adj[1] != base[1] or adj[2] != base[1] or \
           add[2] != shift[1] or add[3] != base[1] or load[1] != jump_reg or load[2] != add[1]:
            continue
        trailing = insns[sh + 5:idx]
        if any(op not in ('li', 'lui', 'addi', 'mv', 'sw') or
               (op == 'sw' and not re.fullmatch(r'\w+,\s*-?[0-9]+\(sp\)', args_.split('#', 1)[0].strip())) or
               (op != 'sw' and args_.split(',', 1)[0].strip() == jump_reg)
               for _, op, args_ in trailing):
            continue
        # A guard must dominate this short sequence. Permit only register-
        # harmless instructions between bound materialization and the guard.
        for g in range(max(0, sh - 12), sh - 1):
            li = insns[g]
            bound = re.fullmatch(r'(\w+),\s*(0x[0-9a-fA-F]+|[0-9]+)', li[2]) if li[1] == 'li' else None
            if not bound:
                continue
            for branch_index in range(g + 1, min(g + 6, sh)):
                branch = insns[branch_index]
                guard = re.match(r'^(\w+),\s*(\w+),\s*([0-9a-fA-F]+)\s*<', branch[2]) if branch[1] in ('bltu', 'bgeu') else None
                if not guard or guard[1] != bound[1] or guard[2] != shift[2]:
                    continue
                before = insns[g + 1:branch_index]
                if any(op not in ('sw', 'li', 'lui', 'addi', 'mv') or
                       (op == 'sw' and not re.fullmatch(r'\w+,\s*-?[0-9]+\(sp\)', args_.split('#', 1)[0].strip())) or
                       (op != 'sw' and args_.split(',', 1)[0].strip() in (bound[1], shift[2]))
                       for _, op, args_ in before):
                    continue
                allow_incoming = None
                after_index = branch_index + 1
                if branch[1] == 'bltu':
                    if int(guard[3], 16) <= pc:
                        continue
                else:
                    # Inverted guard: valid indices jump over one unconditional
                    # branch whose destination is beyond this table jump.
                    if after_index + 1 >= len(insns) or insns[after_index][1] != 'j':
                        continue
                    fallback = TARGET.search(insns[after_index][2])
                    if not fallback or int(fallback[1], 16) <= pc or int(guard[3], 16) != insns[after_index + 1][0]:
                        continue
                    allow_incoming = (branch[0], int(guard[3], 16))
                    after_index += 1
                middle = insns[after_index:sh]
                if any(op not in ('sw', 'li', 'lui', 'addi', 'mv') or
                       (op == 'sw' and not re.fullmatch(r'\w+,\s*-?[0-9]+\(sp\)', args_.split('#', 1)[0].strip())) or
                       (op != 'sw' and args_.split(',', 1)[0].strip() == shift[2])
                       for _, op, args_ in middle):
                    continue
                interval = insns[g:idx + 1]
                if any(right[0] - left[0] not in (2, 4) for left, right in zip(interval, interval[1:])):
                    continue
                if any(insns[g][0] < target <= pc and (origin, target) != allow_incoming for origin, target in branch_edges):
                    continue
                count = int(bound[2], 0) + 1
                address = ((int(base[2], 0) << 12) + int(adj[3], 0)) & 0xffffffff
                targets = read_words(address, count)
                pcs = {item[0] for item in insns}
                if targets is None or any(target not in pcs for target in targets):
                    continue
                return {'table_address': hex(address), 'entries': count, 'targets': sorted(set(hex(target) for target in targets))}
    return None


def _chain(address, parents):
    chain = []
    while address is not None:
        chain.append(address)
        address = parents[address]
    return list(reversed(chain))


def analyze(text, roots=('nih_native_trap', 'nih_native_dispatch'), placed_addresses=None, read_words=None):
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
    branch_edges = set()
    for function in functions.values():
        for pc, op, operands in function['insns']:
            m = TARGET.search(operands) if op in BRANCHES else None
            if m:
                branch_edges.add((pc, int(m[1], 16)))
    tables = {start: [] for start in starts}
    edges = {start: set() for start in starts}
    edge_sites = {}
    indirect = {start: [] for start in starts}
    for start, function in functions.items():
        previous = None
        history = []
        for index, (pc, op, operands) in enumerate(function['insns']):
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
                            edge_sites.setdefault((start, address), {'pc': hex(pc), 'op': op, 'operands': operands})
                            resolved = True
                if not resolved:
                    table = internal_jump_table(function['insns'], index, read_words, branch_edges)
                    if table is not None:
                        tables[start].append({'pc': hex(pc), **table})
                        resolved = True
                if not resolved:
                    indirect[start].append({'pc': hex(pc), 'op': op, 'operands': operands,
                                            'possible_jump_table_hint': op == 'jr' and any('.LJTI' in item[2] for item in history)})
            elif op in BRANCHES:
                m = TARGET.search(operands)
                if m:
                    address = int(m[1], 16)
                    index = bisect.bisect_right(starts, address) - 1
                    if index >= 0 and starts[index] != start and starts[index] == address:
                        edges[start].add(address)
                        edge_sites.setdefault((start, address), {'pc': hex(pc), 'op': op, 'operands': operands})
            previous = (pc, op, operands)
            history = (history + [previous])[-10:]
    seen = set()
    queue = deque(names[name] for name in roots)
    parents = {address: None for address in queue}
    while queue:
        current = queue.popleft()
        if current in seen:
            continue
        seen.add(current)
        for successor in sorted(edges.get(current, ())):
            if successor not in parents:
                parents[successor] = current
                queue.append(successor)
    flash_candidates = [start for start in seen if 0x40060000 <= start < 0x400c0000]
    flash_path = []
    if flash_candidates:
        current = min(flash_candidates, key=lambda start: (len(_chain(start, parents)), start))
        chain = _chain(current, parents)
        flash_path = [{'address': hex(addr), 'symbol': functions[addr]['name'],
                       'incoming_edge': edge_sites.get((chain[index - 1], addr)) if index else None}
                      for index, addr in enumerate(chain)]
    selected = [functions[start]['name'] for start in seen if re.match(r'(?:ssh(?:_|\.)|crypto\.|vt100\.)', functions[start]['name'])]
    unresolved = [{'function': functions[start]['name'], **call} for start in sorted(seen) for call in indirect[start]]
    placed_addresses = placed_addresses or {}
    placed_reachable = [{'address': hex(start), 'symbols': placed_addresses[start]} for start in sorted(seen) if start in placed_addresses]
    resolved_tables = [{'function': functions[start]['name'], **table} for start in sorted(seen) for table in tables[start]]
    return {'roots': list(roots), 'example_existing_xy_flash_path': flash_path, 'resolved_internal_jump_tables': resolved_tables, 'resolved_internal_jump_table_count': len(resolved_tables), 'directly_reachable_placed_functions': placed_reachable, 'directly_reachable_functions': len(seen), 'directly_reachable_ssh_crypto_names': sorted(selected),
            'unresolved_indirect_count': len(unresolved),
            'possible_jump_table_hints': sum(site['possible_jump_table_hint'] for site in unresolved),
            'unresolved_indirect_sites': unresolved,
            'limitations': 'Named direct, adjacent AUIPC/JALR or AUIPC/JR edges and guarded same-function tables only; remaining jump-table hints are unverified; other indirect calls, jumps, interrupt variants and cache-off reachability are not proven.'}


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
    result = analyze(text, placed_addresses=placed, read_words=readonly_elf_reader(args.elf))
    with open(args.output, 'w') as f:
        json.dump(result, f, indent=2)
        f.write('\n')
    print(json.dumps({k: v for k, v in result.items() if k not in ('unresolved_indirect_sites', 'resolved_internal_jump_tables')}, sort_keys=True))


if __name__ == '__main__':
    main()
