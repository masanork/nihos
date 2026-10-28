"""Fail-closed local SP-delta analysis over GNU RV32 disassembly and ELF bytes.

Only constant addi sp,sp adjustments are supported. Calls are assumed to restore
SP on return; callee/indirect/ROM/IRQ stacks and stores through aliases are NOT
proved by this analysis. A derived SP bound is not a memory-footprint proof.
"""
from collections import deque
import hashlib
import re

BRANCHES = ('beq', 'bne', 'blt', 'bge', 'bltu', 'bgeu', 'beqz', 'bnez', 'blez', 'bgez', 'bltz', 'bgtz', 'bgt', 'ble', 'bgtu', 'bleu')
PATTERN = re.compile(r'^\s*([0-9a-f]+):\s+([a-z][a-z0-9.]*)\s*(.*)$')


def require(ok, reason):
    if not ok:
        raise ValueError(reason)


def instructions(text):
    result = {}
    for line in text.splitlines():
        row = PATTERN.match(line)
        if row:
            pc = int(row[1], 16)
            require(pc not in result, 'duplicate instruction address')
            result[pc] = (row[2], row[3].split('#', 1)[0].strip(), row[3])
    return result


def writes_sp(raw):
    """Identify GPR destination x2, including compressed loads and arithmetic."""
    half = int.from_bytes(raw[:2], 'little')
    require(len(raw) >= 2, 'truncated instruction')
    if half & 3 == 3:
        require(len(raw) >= 4 and (half >> 2) & 7 != 7, 'unsupported instruction width')
        word = int.from_bytes(raw[:4], 'little')
        opcode = word & 127
        if opcode in (0x03, 0x13, 0x17, 0x2f, 0x33, 0x37, 0x67, 0x6f, 0x73):
            return (word >> 7) & 31 == 2, 4
        require(opcode in (0x0f, 0x23, 0x63), 'unsupported RV32 opcode')
        return False, 4
    quadrant, funct = half & 3, half >> 13
    rd = (half >> 7) & 31
    if quadrant == 0:
        require(funct in (0, 2, 6), 'unsupported compressed opcode')
        return False, 2  # addi4spn/lw use x8..x15; sw has no destination.
    if quadrant == 1:
        require(funct in range(8), 'unsupported compressed opcode')
        return funct in (0, 2, 3) and rd == 2, 2
    require(quadrant == 2 and funct in (0, 2, 4, 6), 'unsupported compressed opcode')
    if funct == 4:
        # jr/jalr/ebreak have no x2 destination; mv/add do.
        return (half >> 2) & 31 != 0 and rd == 2, 2
    return funct in (0, 2) and rd == 2, 2


def target(operands):
    row = re.search(r'#\s*([0-9a-f]{8})\b', operands) or re.search(r'\b([0-9a-f]{8})\s*<', operands)
    require(row is not None, 'unresolved branch/jump target')
    return int(row[1], 16)


def local_sp_bound(start, code, decoded):
    end = start + len(code)
    pending = deque([(start, 0)])
    seen = {}
    maximum, returns, sinks, calls = 0, 0, 0, 0
    while pending:
        pc, depth = pending.popleft()
        if pc in seen:
            require(seen[pc] == depth, 'inconsistent SP at CFG join or unbounded stack loop')
            continue
        require(start <= pc < end and pc in decoded, 'control flow leaves body or missing disassembly')
        seen[pc] = depth
        op, operands, annotated = decoded[pc]
        write, width = writes_sp(code[pc - start:pc - start + 4])
        require(pc + width <= end, 'instruction exceeds function extent')
        if write:
            adjustment = re.fullmatch(r'sp,sp,(-?\d+)', operands) if op == 'addi' else None
            require(adjustment is not None, 'dynamic or unsupported SP assignment')
            depth -= int(adjustment[1])
            require(0 <= depth <= 1 << 20, 'SP above entry or excessive local stack')
            maximum = max(maximum, depth)
        if op == 'ret' or (op == 'jr' and operands == 'ra'):
            require(depth == 0, 'return with unrestored SP')
            returns += 1
            continue
        if op in ('unimp', 'ebreak'):
            sinks += 1
            continue
        require(op not in ('mret', 'sret', 'uret', 'dret'), 'context-return boundary')
        if op in BRANCHES:
            pending.append((target(annotated), depth))
        elif op in ('j', 'tail', 'jr'):
            destination = target(annotated)
            if not start <= destination < end:
                require(depth == 0, 'tail transfer with unrestored SP')
                sinks += 1
            else:
                pending.append((destination, depth))
            continue
        elif op in ('jal', 'jalr', 'call'):
            require(depth % 16 == 0, 'misaligned SP at ABI call')
            # The full call graph separately retains unresolved call targets.
            calls += 1
        pending.append((pc + width, depth))
    return {'local_sp_decrease_bytes': maximum, 'visited_instructions': len(seen),
            'balanced_returns': returns, 'tail_or_trap_sinks': sinks, 'calls_assumed_to_restore_sp': calls,
            'code_sha256': hashlib.sha256(code).hexdigest(),
            'callee_stacks_proven': False, 'stack_memory_footprint_proven': False}


def derive_missing(nodes, edges, roots, text):
    decoded = instructions(text)
    reached = set()
    pending = list(roots)
    while pending:
        at = pending.pop()
        if at in reached:
            continue
        reached.add(at)
        pending.extend(edges.get(at, ()))
    results = []
    for at in sorted(reached):
        node = nodes[at]
        if node['frame'] is not None:
            continue
        row = {'address': hex(at), 'functions': node['names']}
        try:
            proof = local_sp_bound(at, node['code'], decoded)
        except ValueError as error:
            row.update(derived=False, reason=str(error))
        else:
            node['frame'] = proof['local_sp_decrease_bytes']
            node['frame_provenance'] = 'binary CFG local SP delta; not a full memory-footprint bound'
            row.update(derived=True, **proof)
        results.append(row)
    return results
