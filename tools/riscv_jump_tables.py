"""Recognize a guarded, single-entry RV32 jump-table dispatch block.

GNU disassembly is trusted to decode ELF instructions. The block must have one
entry through li bound; bltu bound,index,default. Other indirect jumps/calls in
the function prevent this limited dominator check. Callees obey the call ABI.
Only immutable allocated PROGBITS loads and intra-function targets are accepted.
"""
import hashlib
import re
import struct
import riscv_stack_flow as FLOW

MAX_ENTRIES = 64
MASK = 0xffffffff


def readonly_regions(data):
    h = struct.unpack_from('<HHIIIIIHHHHHH', data, 16)
    result = []
    for i in range(h[11]):
        row = struct.unpack_from('<10I', data, h[5] + i * 40)
        if row[1] == 1 and row[2] & 2 and row[2] & 5 == 0:
            result.append((row[3], data[row[4]:row[4] + row[5]]))
    return result


def ro_word(regions, address):
    for start, data in regions:
        if start <= address and address + 4 <= start + len(data):
            return int.from_bytes(data[address-start:address-start+4], 'little')
    raise ValueError('jump table load outside immutable allocated data')


def direct_target(annotated):
    try:
        return FLOW.target(annotated)
    except ValueError:
        return None


def verify(nodes, decoded, regions, start, site):
    node = nodes[start]
    addresses = sorted(pc for pc in decoded if start <= pc < node['end'])
    FLOW.require(site in addresses and decoded[site][0] == 'jr', 'not a jump-table jr')
    jump_register = decoded[site][1]
    stop = addresses.index(site)
    guard = None
    for i in range(stop - 1, max(-1, stop - 33), -1):
        pc = addresses[i]
        op, args, annotated = decoded[pc]
        if op != 'bltu' or i == 0:
            continue
        bound, index, _ = args.split(',', 2)
        previous = decoded[addresses[i-1]]
        if previous[0] == 'li' and previous[1].split(',', 1)[0] == bound:
            maximum = int(previous[1].split(',', 1)[1], 0)
            FLOW.require(0 <= maximum < MAX_ENTRIES and bound != index and bound not in ('zero', 'x0') and index not in ('zero', 'x0'), 'unsupported jump-table bound')
            guard = (i, bound, index, maximum, FLOW.target(annotated))
            break
    FLOW.require(guard is not None, 'missing adjacent unsigned range guard')
    i, bound, index, maximum, default = guard
    entry, guard_pc = addresses[i-1], addresses[i]
    FLOW.require(start <= default < node['end'] and default in decoded and not entry <= default <= site,
                 'invalid default branch target')
    FLOW.require(not any(entry <= other <= site for other in nodes if other != start), 'alternate function entry bypasses guard')
    for pc in addresses:
        op, args, annotated = decoded[pc]
        if pc == site or (op == 'jr' and args == 'ra'):
            continue
        if op in FLOW.BRANCHES + ('j', 'jr', 'jal', 'jalr', 'call', 'tail'):
            destination = direct_target(annotated)
            FLOW.require(destination is not None, 'other unresolved transfer may bypass guard')
            if not entry <= pc <= site and destination is not None:
                FLOW.require(not entry < destination <= site, 'external branch bypasses bound initialization or guard')
    registers = {index: set(range(maximum + 1)), bound: {maximum}, 'zero': {0}, 'x0': {0}}
    loads = []
    def value(register):
        return registers.get(register)
    def combine(left, right, operation):
        if left is None or right is None:
            return None
        output = {operation(a, b) & MASK for a in left for b in right}
        FLOW.require(len(output) <= MAX_ENTRIES, 'jump-table value set exceeds limit')
        return output
    for pc in addresses[i+1:stop]:
        op, args, _ = decoded[pc]
        parts = args.split(',')
        if op == 'li':
            registers[parts[0]] = {int(parts[1], 0) & MASK}
        elif op == 'mv':
            registers[parts[0]] = value(parts[1])
        elif op in ('lui', 'auipc'):
            registers[parts[0]] = {((int(parts[1], 0) << 12) + (pc if op == 'auipc' else 0)) & MASK}
        elif op == 'addi':
            registers[parts[0]] = combine(value(parts[1]), {int(parts[2], 0)}, lambda a, b: a + b)
        elif op == 'slli':
            shift = int(parts[2], 0)
            FLOW.require(0 <= shift < 32, 'invalid table index shift')
            registers[parts[0]] = combine(value(parts[1]), {shift}, lambda a, b: a << b)
        elif op == 'add':
            registers[parts[0]] = combine(value(parts[1]), value(parts[2]), lambda a, b: a + b)
        elif op == 'lw':
            memory = re.fullmatch(r'(-?\d+)\(([a-z0-9]+)\)', parts[1])
            FLOW.require(memory is not None and not loads, 'unsupported table load sequence')
            locations = combine(value(memory[2]), {int(memory[1])}, lambda a, b: a + b)
            FLOW.require(locations is not None and len(locations) == maximum + 1, 'incomplete or unknown table address set')
            locations = sorted(locations)
            FLOW.require(locations[0] % 4 == 0 and locations == list(range(locations[0], locations[0] + 4 * len(locations), 4)),
                         'table entries are not contiguous aligned words')
            words = [ro_word(regions, address) for address in locations]
            registers[parts[0]] = set(words)
            loads.append((locations, words))
        elif op != 'nop':
            raise ValueError('unsupported instruction in guarded dispatch block')
        registers['zero'] = registers['x0'] = {0}
    targets = value(jump_register)
    FLOW.require(len(loads) == 1 and targets, 'missing table or unknown jump register')
    FLOW.require(all(start <= target < node['end'] and target in decoded and not entry <= target <= site for target in targets),
                 'jump-table target outside function/instruction boundaries or inside dispatch block')
    locations, words = loads[0]
    table = b''.join(word.to_bytes(4, 'little') for word in words)
    return {'function': node['names'], 'site': hex(site), 'guard': hex(guard_pc),
            'index_maximum': maximum, 'table_start': hex(locations[0]), 'table_entries': len(words),
            'table_sha256': hashlib.sha256(table).hexdigest(), 'targets': [hex(t) for t in sorted(targets)],
            'function_code_sha256': hashlib.sha256(node['code']).hexdigest(),
            'dispatch_code_sha256': hashlib.sha256(node['code'][entry-start:site-start+2]).hexdigest(),
            'normal_call_abi_assumed': True, 'interprocedural_stack_qualified': False}


def resolve(nodes, unknown, text, regions, reachable=None):
    decoded = FLOW.instructions(text)
    accepted, rejected = [], []
    for start, sites in unknown.items():
        if reachable is not None and start not in reachable:
            continue
        for site in list(sites):
            if site['kind'] != 'indirect-transfer' or not site.get('instruction', '').startswith('jr '):
                continue
            try:
                proof = verify(nodes, decoded, regions, start, int(site['pc'], 16))
            except (ValueError, IndexError) as error:
                rejected.append({'functions': nodes[start]['names'], 'site': site['pc'], 'reason': str(error)})
            else:
                accepted.append(proof)
                sites.remove(site)
    return {'resolved': accepted, 'unresolved': rejected}
