//! Japanese Dictionary lookup engine supporting:
//! 1. MeOS format (IMD1: sorted keys + binary search)
//! 2. nihos format (NFST: Radix Tree + String Interner arena)
//!
//! Designed for zero heap allocations and Flash Memory-Mapped I/O (XIP).

const std = @import("std");
const ime_omni = @import("ime_omni.zig");
const document = @import("document.zig");

pub const code_section = if (@import("builtin").os.tag == .freestanding) ".flash.xytext" else if (@import("builtin").object_format == .macho) "__TEXT,__text" else ".text";

pub const MeosDict = struct {
    bytes: []const u8,
    count: u32,
    total: u32,

    pub fn init(bytes: []const u8) linksection(code_section) !MeosDict {
        if (bytes.len < 12) return error.InvalidHeader;
        if (!std.mem.eql(u8, bytes[0..4], "IMD1")) return error.InvalidMagic;
        const count = std.mem.readInt(u32, bytes[4..8], .little);
        const total = std.mem.readInt(u32, bytes[8..12], .little);
        if (bytes.len < total) return error.Truncated;
        return .{ .bytes = bytes, .count = count, .total = total };
    }

    pub fn lookup(self: MeosDict, key: []const u8, out_cands: [][]const u8) linksection(code_section) usize {
        var lo: u32 = 0;
        var hi: u32 = self.count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const off = std.mem.readInt(u32, self.bytes[12 + 4 * mid ..][0..4], .little);
            if (off >= self.bytes.len) return 0;
            const klen = self.bytes[off];
            if (off + 1 + klen > self.bytes.len) return 0;
            const entry_key = self.bytes[off + 1 .. off + 1 + klen];
            const order = std.mem.order(u8, entry_key, key);
            switch (order) {
                .eq => {
                    if (off + 3 + klen > self.bytes.len) return 0;
                    const dlen = std.mem.readInt(u16, self.bytes[off + 1 + klen ..][0..2], .little);
                    if (off + 3 + klen + dlen > self.bytes.len) return 0;
                    const data = self.bytes[off + 3 + klen .. off + 3 + klen + dlen];
                    var count: usize = 0;
                    var pos: usize = 0;
                    while (pos < data.len and count < out_cands.len) {
                        const end = std.mem.indexOfScalarPos(u8, data, pos, 0) orelse data.len;
                        if (end > pos) {
                            out_cands[count] = data[pos..end];
                            count += 1;
                        }
                        pos = end + 1;
                    }
                    return count;
                },
                .lt => lo = mid + 1,
                .gt => hi = mid,
            }
        }
        return 0;
    }
};

pub const NfstDict = struct {
    bytes: []const u8,
    entry_count: u32,
    trie: []const u8,
    cand_blob: []const u8,
    arena: []const u8,

    pub fn init(bytes: []const u8) linksection(code_section) !NfstDict {
        if (bytes.len < 36) return error.InvalidHeader;
        if (!std.mem.eql(u8, bytes[0..4], "NFST")) return error.InvalidMagic;
        const entry_count = std.mem.readInt(u32, bytes[8..12], .little);
        const trie_off = std.mem.readInt(u32, bytes[12..16], .little);
        const trie_sz = std.mem.readInt(u32, bytes[16..20], .little);
        const cand_off = std.mem.readInt(u32, bytes[20..24], .little);
        const cand_sz = std.mem.readInt(u32, bytes[24..28], .little);
        const arena_off = std.mem.readInt(u32, bytes[28..32], .little);
        const arena_sz = std.mem.readInt(u32, bytes[32..36], .little);

        if (bytes.len < arena_off + arena_sz) return error.Truncated;

        return .{
            .bytes = bytes,
            .entry_count = entry_count,
            .trie = bytes[trie_off .. trie_off + trie_sz],
            .cand_blob = bytes[cand_off .. cand_off + cand_sz],
            .arena = bytes[arena_off .. arena_off + arena_sz],
        };
    }

    pub fn lookup(self: NfstDict, key: []const u8, out_cands: [][]const u8) linksection(code_section) usize {
        var node_off: usize = 0;
        var key_idx: usize = 0;

        while (node_off < self.trie.len) {
            const edge_len = self.trie[node_off];
            const edge = self.trie[node_off + 1 .. node_off + 1 + edge_len];
            const cand_off = std.mem.readInt(u32, self.trie[node_off + 1 + edge_len ..][0..4], .little);
            const child_count = self.trie[node_off + 5 + edge_len];
            const children_raw = self.trie[node_off + 6 + edge_len .. node_off + 6 + edge_len + 4 * child_count];

            if (edge.len > 0) {
                if (key.len - key_idx < edge.len) return 0;
                if (!std.mem.eql(u8, key[key_idx .. key_idx + edge.len], edge)) return 0;
                key_idx += edge.len;
            }

            if (key_idx == key.len) {
                if (cand_off == 0xFFFFFFFF or cand_off >= self.cand_blob.len) return 0;
                const count = self.cand_blob[cand_off];
                var n: usize = 0;
                var p = cand_off + 1;
                while (n < count and n < out_cands.len and p + 4 <= self.cand_blob.len) {
                    const str_off = @as(u32, self.cand_blob[p]) |
                        (@as(u32, self.cand_blob[p + 1]) << 8) |
                        (@as(u32, self.cand_blob[p + 2]) << 16);
                    const str_len = self.cand_blob[p + 3];
                    p += 4;
                    if (str_off + str_len <= self.arena.len) {
                        out_cands[n] = self.arena[str_off .. str_off + str_len];
                        n += 1;
                    }
                }
                return n;
            }

            const next_byte = key[key_idx];
            var next_node_off: ?usize = null;
            var c: usize = 0;
            while (c < child_count) : (c += 1) {
                const ch_off = std.mem.readInt(u32, children_raw[c * 4 ..][0..4], .little);
                if (ch_off < self.trie.len) {
                    const ch_edge_len = self.trie[ch_off];
                    if (ch_edge_len > 0 and self.trie[ch_off + 1] == next_byte) {
                        next_node_off = ch_off;
                        break;
                    }
                }
            }

            if (next_node_off) |nxt| {
                node_off = nxt;
            } else {
                return 0;
            }
        }
        return 0;
    }

    /// Prefix callback definition for bunsetsu / morphology search
    pub const PrefixCallback = *const fn (ctx: *anyopaque, prefix_len: usize, cands: []const []const u8) bool;

    /// Common Prefix Search: traverses along `key` and calls `cb` for every prefix that matches a word.
    /// Crucial for Viterbi / DP phrase conversion!
    pub fn commonPrefixSearch(
        self: NfstDict,
        key: []const u8,
        ctx: *anyopaque,
        cb: PrefixCallback,
    ) linksection(code_section) void {
        var node_off: usize = 0;
        var key_idx: usize = 0;
        var cand_buf: [16][]const u8 = undefined;

        while (node_off < self.trie.len) {
            const edge_len = self.trie[node_off];
            const edge = self.trie[node_off + 1 .. node_off + 1 + edge_len];
            const cand_off = std.mem.readInt(u32, self.trie[node_off + 1 + edge_len ..][0..4], .little);
            const child_count = self.trie[node_off + 5 + edge_len];
            const children_raw = self.trie[node_off + 6 + edge_len .. node_off + 6 + edge_len + 4 * child_count];

            if (edge.len > 0) {
                if (key.len - key_idx < edge.len) return;
                if (!std.mem.eql(u8, key[key_idx .. key_idx + edge.len], edge)) return;
                key_idx += edge.len;
            }

            // If this node represents a valid word, call callback
            if (cand_off != 0xFFFFFFFF and cand_off < self.cand_blob.len) {
                const count = self.cand_blob[cand_off];
                var n: usize = 0;
                var p = cand_off + 1;
                while (n < count and n < cand_buf.len and p + 4 <= self.cand_blob.len) {
                    const str_off = @as(u32, self.cand_blob[p]) |
                        (@as(u32, self.cand_blob[p + 1]) << 8) |
                        (@as(u32, self.cand_blob[p + 2]) << 16);
                    const str_len = self.cand_blob[p + 3];
                    p += 4;
                    if (str_off + str_len <= self.arena.len) {
                        cand_buf[n] = self.arena[str_off .. str_off + str_len];
                        n += 1;
                    }
                }
                if (n > 0) {
                    const cont = cb(ctx, key_idx, cand_buf[0..n]);
                    if (!cont) return;
                }
            }

            if (key_idx >= key.len) return;

            const next_byte = key[key_idx];
            var next_node_off: ?usize = null;
            var c: usize = 0;
            while (c < child_count) : (c += 1) {
                const ch_off = std.mem.readInt(u32, children_raw[c * 4 ..][0..4], .little);
                if (ch_off < self.trie.len) {
                    const ch_edge_len = self.trie[ch_off];
                    if (ch_edge_len > 0 and self.trie[ch_off + 1] == next_byte) {
                        next_node_off = ch_off;
                        break;
                    }
                }
            }

            if (next_node_off) |nxt| {
                node_off = nxt;
            } else {
                return;
            }
        }
    }

    pub fn omniProvider(self: *const NfstDict) linksection(code_section) ime_omni.OmniProvider {
        return .{
            .ctx = @constCast(self),
            .queryFn = omniQuery,
            .learnFn = null,
        };
    }

    fn omniQuery(
        ctx: *anyopaque,
        kind: ime_omni.PrefixKind,
        prefix_char: u8,
        query_key: []const u8,
        out: *ime_omni.CandidateList,
    ) linksection(code_section) void {
        _ = prefix_char;
        const self: *const NfstDict = @ptrCast(@alignCast(ctx));
        if (kind == .kanji) {
            var cands: [16][]const u8 = undefined;
            const n = self.lookup(query_key, &cands);
            for (cands[0..n]) |c| {
                _ = out.append(c, "");
            }
        }
    }
};

test "MeosDict and NfstDict sanity test on mini dictionary" {
    const meos_bytes = @embedFile("fixtures/mini_meos.bin");
    const nfst_bytes = @embedFile("fixtures/mini_nfst.bin");

    const meos = try MeosDict.init(meos_bytes);
    const nfst = try NfstDict.init(nfst_bytes);

    var cands_meos: [16][]const u8 = undefined;
    var cands_nfst: [16][]const u8 = undefined;

    // Test 1: "いk" -> "行"
    const m1 = meos.lookup("いk", &cands_meos);
    const n1 = nfst.lookup("いk", &cands_nfst);
    try std.testing.expectEqual(m1, n1);
    try std.testing.expectEqualStrings("行", cands_meos[0]);
    try std.testing.expectEqualStrings("行", cands_nfst[0]);

    // Test 2: "うつくs" -> "美"
    const m2 = meos.lookup("うつくs", &cands_meos);
    const n2 = nfst.lookup("うつくs", &cands_nfst);
    try std.testing.expectEqual(m2, n2);
    try std.testing.expectEqualStrings("美", cands_meos[0]);
    try std.testing.expectEqualStrings("美", cands_nfst[0]);

    // Test 3: Common prefix search on "いk"
    const Context = struct {
        hit_count: usize = 0,
        fn callback(ctx_ptr: *anyopaque, prefix_len: usize, cands: []const []const u8) bool {
            _ = prefix_len;
            _ = cands;
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            self.hit_count += 1;
            return true;
        }
    };
    var test_ctx: Context = .{};
    nfst.commonPrefixSearch("いk", &test_ctx, Context.callback);
    try std.testing.expect(test_ctx.hit_count >= 1);
}

test "Integration: NfstDict seamlessly powers OmniIme conversion & commit" {
    const nfst_bytes = @embedFile("fixtures/mini_nfst.bin");
    const nfst = try NfstDict.init(nfst_bytes);
    const prov = nfst.omniProvider();

    const DocType = document.Document(1024, 32, 512, 16, 256);
    var doc: DocType = .{};
    var ime: ime_omni.OmniIme = .{};

    // Type "IKu" -> reading "い", okuri "く" (key "いk") -> auto-triggers conversion to "▼行く"
    for ("IKu") |ch| {
        try ime.handleKey(&doc, prov, ch);
    }
    try std.testing.expectEqual(ime_omni.OmniPhase.selecting, ime.phase);
    try std.testing.expectEqualStrings("▼行く", doc.preedit.slice());

    // Commit with Enter ('\n')
    try ime.handleKey(&doc, prov, '\n');
    try std.testing.expectEqual(ime_omni.OmniPhase.idle, ime.phase);
    try std.testing.expectEqualStrings("行く", doc.slice());
}
