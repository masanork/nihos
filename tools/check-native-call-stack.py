#!/usr/bin/env python3
"""Inventory reachable native task call chains. Unknown edges remain unresolved.

This is a conservative structural diagnostic, not a whole-stack qualification:
branches need not form feasible paths, tail transfers are charged as calls, and
metadata alone cannot cover indirect transfers, recursion or unmeasured code.
"""
import argparse
from bisect import bisect_right
import hashlib
import json
from pathlib import Path
import re
import runpy
import struct
import subprocess
import riscv_stack_flow


def require(ok, reason):
    if not ok:
        raise ValueError(reason)


def elf_functions(data):
    require(data[:7] == b'\x7fELF\x01\x01\x01', 'expected ELF32 little endian')
    h = struct.unpack_from('<HHIIIIIHHHHHH', data, 16)
    require(h[0] == 2 and h[1] == 243 and h[10] == 40, 'expected linked RISC-V ELF32')
    sections = [struct.unpack_from('<10I', data, h[5] + i * 40) for i in range(h[11])]
    st = sections[h[12]]
    section_names = data[st[4]:st[4] + st[5]]
    functions = []
    code = {}
    frames = []
    for s in sections:
        if s[1] == 2:
            strings_section = sections[s[6]]
            strings = data[strings_section[4]:strings_section[4] + strings_section[5]]
            for p in range(s[4], s[4] + s[5], 16):
                name, address, size, info, _, index = struct.unpack_from('<IIIBBH', data, p)
                if name and info & 15 == 2 and index and size:
                    functions.append((strings[name:strings.index(0, name)].decode(), address, address + size))
                    body = sections[index]
                    require(body[2] & 4 and body[3] <= address < address + size <= body[3] + body[5], 'function outside executable section')
                    code[address] = data[body[4] + address - body[3]:body[4] + address - body[3] + size]
        if section_names[s[0]:section_names.index(0, s[0])] == b'.stack_sizes':
            frames.append(data[s[4]:s[4] + s[5]])
    require(functions and len(frames) == 1, 'missing functions or unique static frame section')
    module = runpy.run_path(str(Path(__file__).with_name('check-native-image.py')))
    rows = module['stack_size_rows'](frames[0], functions)
    nodes = {}
    for name, start, end in functions:
        node = nodes.setdefault(start, {'names': [], 'end': end, 'frame': None, 'code': code[start]})
        require(node['end'] == end, 'conflicting function extents')
        node['names'].append(name)
    for row in rows:
        nodes[int(row['address'], 16)]['frame'] = row['bytes']
    for node in nodes.values():
        node['names'].sort()
    return nodes


def transfers(text, nodes):
    starts = sorted(nodes)
    edges = {start: set() for start in nodes}
    unknown = {start: [] for start in nodes}
    counts = dict.fromkeys(nodes, 0)
    pattern = re.compile(r'^\s*([0-9a-f]+):\s+([a-z][a-z0-9.]*)\s*(.*)$')
    for line in text.splitlines():
        match = pattern.match(line)
        if not match:
            continue
        pc, op, operands = int(match[1], 16), match[2], match[3]
        i = bisect_right(starts, pc) - 1
        if i < 0 or pc >= nodes[starts[i]]['end']:
            continue
        start = starts[i]
        counts[start] += 1
        if op in ('mret', 'sret', 'uret', 'dret'):
            unknown[start].append({'pc': hex(pc), 'kind': 'context-return-boundary', 'instruction': op})
        if op == 'ecall':
            unknown[start].append({'pc': hex(pc), 'kind': 'syscall-stack-boundary', 'instruction': op})
        branches = ('beq', 'bne', 'blt', 'bge', 'bltu', 'bgeu', 'beqz', 'bnez', 'blez', 'bgez', 'bltz', 'bgtz', 'bgt', 'ble', 'bgtu', 'bleu')
        if op not in ('jal', 'jalr', 'call', 'tail', 'j', 'jr') + branches:
            continue
        if op == 'jr' and operands.strip() == 'ra':
            continue
        target = re.search(r'#\s*([0-9a-f]{8})\b', operands) or re.search(r'\b([0-9a-f]{8})\s*<', operands)
        if target is None:
            unknown[start].append({'pc': hex(pc), 'kind': 'indirect-transfer', 'instruction': op + ' ' + operands})
            continue
        address = int(target[1], 16)
        if start <= address < nodes[start]['end']:
            continue
        if address not in nodes:
            unknown[start].append({'pc': hex(pc), 'kind': 'unmeasured-target', 'target': hex(address), 'instruction': op + ' ' + operands})
            continue
        # Tail calls conservatively include the caller; no unwinding assumed.
        edges[start].add(address)
    for start, count in counts.items():
        if not count:
            unknown[start].append({'pc': hex(start), 'kind': 'no-disassembly'})
    return edges, unknown


def analyze(nodes, edges, unknown, root):
    require(root in nodes, 'missing root function')
    reached, cycles, cache = set(), set(), {}
    def visit(at, active):
        reached.add(at)
        if at in active:
            cycles.update(active[active.index(at):])
            return 0, []
        if at in cache:
            return cache[at]
        candidates = [visit(child, active + (at,)) for child in sorted(edges.get(at, ()))]
        score, path = max(candidates, key=lambda item: item[0], default=(0, []))
        frame = nodes[at]['frame']
        cache[at] = score + (frame if frame is not None else 0), [at] + path
        return cache[at]
    total, path = visit(root, ())
    def record(at):
        return {'address': hex(at), 'functions': nodes[at]['names'], 'frame_bytes': nodes[at]['frame'],
                **({'frame_provenance': nodes[at]['frame_provenance']} if 'frame_provenance' in nodes[at] else {})}
    missing = [record(at) for at in sorted(reached) if nodes[at]['frame'] is None]
    unresolved = [{**record(at), 'sites': unknown[at]} for at in sorted(reached) if unknown.get(at)]
    return {'root': record(root), 'reachable_functions': len(reached),
            'known_frames_on_largest_structural_chain_bytes': total,
            'structural_chain': [record(at) for at in path],
            'missing_frames': missing, 'unresolved_transfers': unresolved,
            'recursive_functions': [record(at) for at in sorted(cycles)],
            'graph_closed': not (missing or unresolved or cycles),
            'whole_call_stack_qualified': False}



def add_candidate_edges(nodes, edges, unknown, specifications):
    """Include possible callees without treating a source-level binding as proof."""
    result = []
    for specification in specifications:
        caller, callee = specification.split(':', 1)
        parents = [at for at in nodes if caller in nodes[at]['names']]
        children = [at for at in nodes if callee in nodes[at]['names']]
        require(len(parents) == len(children) == 1, 'missing/ambiguous candidate edge')
        parent, child = parents[0], children[0]
        sites = [s for s in unknown[parent] if s['kind'] == 'indirect-transfer' and s.get('instruction', '').startswith('jalr ')]
        require(len(sites) == 1, 'candidate edge needs exactly one unresolved indirect call site')
        edges[parent].add(child)
        row = {'caller': caller, 'callee': callee, 'call_site': sites[0]['pc'], 'target_exclusivity_proven': False}
        sites[0].setdefault('candidate_callees', []).append(callee)
        result.append(row)
    return result

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('elf', type=Path)
    parser.add_argument('report', type=Path)
    parser.add_argument('--objdump', required=True)
    parser.add_argument('--root', action='append', default=[])
    parser.add_argument('--require-closed', action='store_true')
    parser.add_argument('--candidate-edge', action='append', default=[], metavar='CALLER:CALLEE')
    parser.add_argument('--derive-frames', action='store_true', help='derive missing local SP bounds from binary CFG; preserves unresolved transfers')
    args = parser.parse_args()
    args.report.unlink(missing_ok=True)
    data = args.elf.read_bytes()
    nodes = elf_functions(data)
    output = subprocess.check_output([args.objdump, '-d', '--no-show-raw-insn', str(args.elf)], text=True, timeout=60)
    edges, unknown = transfers(output, nodes)
    candidate_edges = add_candidate_edges(nodes, edges, unknown, args.candidate_edge)
    roots = args.root or ['nih_storage_task_entry', 'fatfs_runtime.serve', 'fatfs_runtime.runClient']
    results = []
    root_addresses = []
    for name in roots:
        found = [at for at in nodes if name in nodes[at]['names']]
        require(len(found) == 1, 'missing/ambiguous root: ' + name)
        root_addresses.append(found[0])
    derivations = riscv_stack_flow.derive_missing(nodes, edges, root_addresses, output) if args.derive_frames else []
    results = [analyze(nodes, edges, unknown, at) for at in root_addresses]
    result = {'schema': 1, 'evidence': 'static structural call-chain inventory; no execution or whole-stack qualification',
        'elf_sha256': hashlib.sha256(data).hexdigest(), 'analyzer_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'disassembly_sha256': hashlib.sha256(output.encode()).hexdigest(),
        'objdump_version': subprocess.check_output([args.objdump, '--version'], text=True).splitlines()[0],
        'sp_flow_analyzer_sha256': hashlib.sha256(Path(riscv_stack_flow.__file__).read_bytes()).hexdigest(),
        'candidate_edges': candidate_edges, 'frame_derivations': derivations, 'roots': results, 'whole_call_stack_qualified': False}
    args.report.write_text(json.dumps(result, indent=2) + '\n')
    for row in results:
        print(row['root']['functions'][0] + ': known structural sum=' + str(row['known_frames_on_largest_structural_chain_bytes']) +
              ', missing frames=' + str(len(row['missing_frames'])) + ', unresolved functions=' + str(len(row['unresolved_transfers'])))
    if args.require_closed and not all(row['graph_closed'] for row in results):
        raise SystemExit('Call graph is incomplete; whole-stack gate remains open')


if __name__ == '__main__':
    main()
