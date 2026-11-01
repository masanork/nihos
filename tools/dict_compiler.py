#!/usr/bin/env python3
"""dict_compiler.py - Compiles SKK dictionaries into:
1. MeOS format (IMD1: sorted keys + binary search offset table)
2. nihos format (NFST: Radix Tree + String Interner arena)

Usage:
  python3 tools/dict_compiler.py tools/ime/cache/SKK-JISYO.L -o build/dict
"""

import argparse
import os
import re
import struct
import sys
from collections import defaultdict

HIRA = re.compile(r'^[ぁ-ゖー]+[a-z]?$')


def read_skk(paths):
    """Read and parse one or more SKK dictionaries."""
    entries = {}
    for path in paths:
        raw = open(path, 'rb').read()
        head = raw[:300].decode('ascii', 'ignore')
        enc = 'euc-jp' if 'euc' in head.lower() else 'utf-8'
        text = raw.decode(enc, 'replace')
        for line in text.splitlines():
            if not line or line.startswith(';') or ' /' not in line:
                continue
            parts = line.split(' ', 1)
            if len(parts) < 2:
                continue
            key, rest = parts[0], parts[1]
            if not HIRA.match(key):
                continue
            cands = []
            for c in rest.strip().strip('/').split('/'):
                c = c.split(';', 1)[0].strip()
                if not c or c.startswith('(') or '\\' in c or '\ufffd' in c:
                    continue
                cands.append(c)
            if cands:
                cur = entries.setdefault(key, [])
                for c in cands:
                    if c not in cur:
                        cur.append(c)
    return entries


def build_meos_imd1(entries, max_cands=24):
    """Build MeOS IMD1 format binary."""
    keys = sorted(entries.keys(), key=lambda k: k.encode('utf-8'))
    bodies = []
    for k in keys:
        kb = k.encode('utf-8')
        cands = entries[k][:max_cands]
        data = b''.join(c.encode('utf-8') + b'\0' for c in cands)
        if len(kb) > 255 or len(data) > 65535:
            continue
        bodies.append((kb, data))

    count = len(bodies)
    pos = 12 + 4 * count
    offs = []
    blob = bytearray()
    for kb, data in bodies:
        offs.append(pos + len(blob))
        blob += bytes([len(kb)]) + kb + struct.pack('<H', len(data)) + data
    total = pos + len(blob)
    out = b'IMD1' + struct.pack('<II', count, total) + b''.join(struct.pack('<I', o) for o in offs) + bytes(blob)
    return out


class RadixNode:
    def __init__(self, edge=b''):
        self.edge = edge  # bytes
        self.cand_idx = None  # index into candidate table, or None
        self.children = []  # list of RadixNode


def build_radix_tree(entries):
    """Build a compact Radix Tree from entries."""
    root = RadixNode()

    # Sort keys lexicographically
    sorted_items = sorted(entries.items(), key=lambda item: item[0].encode('utf-8'))

    for key, cand_list in sorted_items:
        kb = key.encode('utf-8')
        curr = root
        i = 0
        while i < len(kb):
            # Check children of curr
            found_child = None
            for child in curr.children:
                if child.edge[0] == kb[i]:
                    found_child = child
                    break

            if not found_child:
                # Add new child with the rest of kb
                new_node = RadixNode(edge=kb[i:])
                new_node.cand_list = cand_list
                curr.children.append(new_node)
                curr.children.sort(key=lambda c: c.edge[0])
                break

            # Child found, find common prefix length
            common = 0
            while common < len(found_child.edge) and (i + common) < len(kb) and found_child.edge[common] == kb[i + common]:
                common += 1

            if common == len(found_child.edge):
                # Full edge match, continue downwards
                i += common
                curr = found_child
                if i == len(kb):
                    found_child.cand_list = cand_list
            else:
                # Partial match, split found_child
                split_node = RadixNode(edge=found_child.edge[:common])
                found_child.edge = found_child.edge[common:]
                split_node.children.append(found_child)

                if i + common == len(kb):
                    split_node.cand_list = cand_list
                else:
                    new_leaf = RadixNode(edge=kb[i + common:])
                    new_leaf.cand_list = cand_list
                    split_node.children.append(new_leaf)

                split_node.children.sort(key=lambda c: c.edge[0])

                # Replace found_child in curr.children with split_node
                idx = curr.children.index(found_child)
                curr.children[idx] = split_node
                break

    return root


def serialize_nihos_nfst(entries, max_cands=24):
    """Build nihos Radix Tree + String Interner binary (NFST)."""
    # 1. Build string interner arena
    arena = bytearray()
    string_map = {}  # str -> (offset, len)

    def intern(s):
        if s in string_map:
            return string_map[s]
        b = s.encode('utf-8')
        off = len(arena)
        arena.extend(b)
        string_map[s] = (off, len(b))
        return (off, len(b))

    # 2. Build candidate table
    cand_blob = bytearray()
    cand_offsets = {}  # id(cand_list) -> offset

    def encode_cands(cand_list):
        cl = cand_list[:max_cands]
        off = len(cand_blob)
        cand_blob.append(len(cl))
        for c in cl:
            str_off, str_len = intern(c)
            # pack as u24 LE + u8
            cand_blob.extend(struct.pack('<I', str_off)[:3])
            cand_blob.append(str_len)
        return off

    # 3. Build Radix tree
    root = build_radix_tree(entries)

    # Assign candidate offsets to nodes with cand_list
    def assign_cands(node):
        if hasattr(node, 'cand_list') and node.cand_list:
            node.cand_off = encode_cands(node.cand_list)
        else:
            node.cand_off = 0xFFFFFFFF
        for ch in node.children:
            assign_cands(ch)

    assign_cands(root)

    # 4. Serialize Radix Tree nodes in post-order or BFS
    # Format of a node:
    #   edge_len: u8
    #   edge_bytes: [edge_len]u8
    #   cand_offset: u32 (0xFFFFFFFF if none)
    #   child_count: u8
    #   child_offsets: [child_count]u32 (offsets within trie section)
    #
    # We do a two-pass BFS serialization to resolve child offsets.
    all_nodes = []
    queue = [root]
    while queue:
        n = queue.pop(0)
        all_nodes.append(n)
        for ch in n.children:
            queue.append(ch)

    # Compute node offsets
    node_offsets = {}
    curr_off = 0
    for n in all_nodes:
        node_offsets[n] = curr_off
        # size: 1 (edge_len) + len(edge) + 4 (cand_off) + 1 (child_count) + 4 * num_children
        node_size = 1 + len(n.edge) + 4 + 1 + 4 * len(n.children)
        curr_off += node_size

    trie_blob = bytearray()
    for n in all_nodes:
        trie_blob.append(len(n.edge))
        trie_blob.extend(n.edge)
        trie_blob.extend(struct.pack('<I', n.cand_off))
        trie_blob.append(len(n.children))
        for ch in n.children:
            trie_blob.extend(struct.pack('<I', node_offsets[ch]))

    # 5. Pack final binary:
    # Header (32 bytes):
    #   0..4: 'NFST'
    #   4..6: version (1)
    #   6..8: flags (0)
    #   8..12: entry_count
    #   12..16: trie_offset
    #   16..20: trie_size
    #   20..24: cand_offset
    #   24..28: cand_size
    #   28..32: arena_offset
    #   32..36: arena_size
    header_size = 36
    trie_off = header_size
    cand_off = trie_off + len(trie_blob)
    arena_off = cand_off + len(cand_blob)
    total_size = arena_off + len(arena)

    header = b'NFST' + struct.pack(
        '<HHIIIIIII',
        1,  # version
        0,  # flags
        len(entries),
        trie_off,
        len(trie_blob),
        cand_off,
        len(cand_blob),
        arena_off,
        len(arena)
    )

    out = header + bytes(trie_blob) + bytes(cand_blob) + bytes(arena)
    return out, len(trie_blob), len(cand_blob), len(arena)


def main():
    parser = argparse.ArgumentParser(description='Compile SKK dictionaries into MeOS and nihos formats.')
    parser.add_argument('inputs', nargs='+', help='Input SKK dictionary file(s)')
    parser.add_argument('-o', '--out-prefix', default='build/dict', help='Output file prefix (without extension)')
    parser.add_argument('--max-cands', type=int, default=24, help='Maximum candidates per entry')
    args = parser.parse_args()

    os.makedirs(os.path.dirname(args.out_prefix) or '.', exist_ok=True)

    print(f"Reading SKK dictionaries: {', '.join(args.inputs)}...")
    entries = read_skk(args.inputs)
    print(f"Loaded {len(entries)} valid hiragana entries.")

    # 1. Build MeOS IMD1
    print("\nBuilding MeOS IMD1 format...")
    meos_bin = build_meos_imd1(entries, max_cands=args.max_cands)
    meos_path = args.out_prefix + "_meos.bin"
    with open(meos_path, 'wb') as f:
        f.write(meos_bin)
    print(f"  -> {meos_path}: {len(meos_bin):,} bytes ({len(meos_bin) / (1024*1024):.2f} MB)")

    # 2. Build nihos NFST
    print("\nBuilding nihos NFST (Radix Tree + String Interner) format...")
    nfst_bin, trie_sz, cand_sz, arena_sz = serialize_nihos_nfst(entries, max_cands=args.max_cands)
    nfst_path = args.out_prefix + "_nfst.bin"
    with open(nfst_path, 'wb') as f:
        f.write(nfst_bin)
    print(f"  -> {nfst_path}: {len(nfst_bin):,} bytes ({len(nfst_bin) / (1024*1024):.2f} MB)")
    print(f"     [Trie: {trie_sz:,} B, Candidates: {cand_sz:,} B, String Arena: {arena_sz:,} B]")

    # Comparison summary
    diff = len(nfst_bin) - len(meos_bin)
    pct = (len(nfst_bin) / len(meos_bin) - 1.0) * 100.0
    print("\n=== Size Comparison ===")
    print(f"MeOS IMD1:   {len(meos_bin):>10,} bytes")
    print(f"nihos NFST:  {len(nfst_bin):>10,} bytes ({pct:+.1f}%)")


if __name__ == '__main__':
    main()
