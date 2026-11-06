//! Experimental bounded, copy-out NFST reader. Reader.read(offset, out) must
//! return the number of bytes read from one immutable, pinned object. The owner
//! must invalidate this cache before releasing its pin or rebinding the reader.
const std = @import("std");

pub const page_bytes = 4096;
pub const max_key_bytes = 128;
pub const max_candidates = 8;
pub const Error = error{ Io, Corrupt, InvalidKey };
pub const Candidates = struct {
    bytes: [max_candidates][255]u8 = @splat(@splat(0)),
    lengths: [max_candidates]u8 = @splat(0),
    count: u8 = 0,
    truncated: bool = false,
    pub fn slice(self: *const Candidates, index: usize) []const u8 {
        return self.bytes[index][0..self.lengths[index]];
    }
};

pub fn Dictionary(comptime Reader: type) type {
    return struct {
        const Self = @This();
        reader: *Reader,
        length: u64,
        trie_start: u64,
        trie_length: u32,
        cand_start: u64,
        cand_length: u32,
        arena_start: u64,
        arena_length: u32,
        // The root page is revisited for every trie search. Keep it apart
        // from the rotating data page; both belong to the same pinned object.
        root_cache: [page_bytes]u8 = @splat(0),
        root_cache_valid: bool = false,
        root_cache_length: usize = 0,
        root_cache_enabled: bool = true,
        cache: [page_bytes]u8 = @splat(0),
        cache_start: u64 = 0,
        cache_length: usize = 0,
        cache_valid: bool = false,
        closed: bool = false,
        cache_misses: u64 = 0,

        pub fn invalidate(self: *Self) void {
            self.closed = true;
            self.cache_valid = false;
            self.root_cache_valid = false;
        }

        fn read(self: *Self, offset: u64, out: []u8) Error!void {
            if (self.closed) return error.Io;
            if (offset > self.length or out.len > self.length - offset) return error.Corrupt;
            var done: usize = 0;
            while (done < out.len) {
                const at = offset + done;
                if (self.root_cache_enabled and at < page_bytes) {
                    if (!self.root_cache_valid) {
                        const n: usize = @intCast(@min(page_bytes, self.length));
                        const got = self.reader.read(0, self.root_cache[0..n]) catch {
                            self.invalidate();
                            return error.Io;
                        };
                        if (got != n) {
                            self.invalidate();
                            return error.Io;
                        }
                        self.root_cache_length = n;
                        self.root_cache_valid = true;
                        self.cache_misses += 1;
                    }
                    const local: usize = @intCast(at);
                    const n = @min(out.len - done, self.root_cache_length - local);
                    @memcpy(out[done..][0..n], self.root_cache[local..][0..n]);
                    done += n;
                    continue;
                }
                if (!self.cache_valid or at < self.cache_start or at >= self.cache_start + self.cache_length) {
                    self.cache_valid = false;
                    self.cache_start = at - at % page_bytes;
                    const n: usize = @intCast(@min(page_bytes, self.length - self.cache_start));
                    const got = self.reader.read(self.cache_start, self.cache[0..n]) catch {
                        self.invalidate();
                        return error.Io;
                    };
                    if (got != n) {
                        self.invalidate();
                        return error.Io;
                    }
                    self.cache_length = n;
                    self.cache_valid = true;
                    self.cache_misses += 1;
                }
                const local: usize = @intCast(at - self.cache_start);
                const n = @min(out.len - done, self.cache_length - local);
                @memcpy(out[done..][0..n], self.cache[local..][0..n]);
                done += n;
            }
        }
        fn byte(self: *Self, offset: u64) Error!u8 {
            var value: [1]u8 = undefined;
            try self.read(offset, &value);
            return value[0];
        }
        fn word(self: *Self, offset: u64) Error!u32 {
            var value: [4]u8 = undefined;
            try self.read(offset, &value);
            return std.mem.readInt(u32, &value, .little);
        }
        fn fits(offset: u64, size: u64, limit: u64) bool {
            return offset <= limit and size <= limit - offset;
        }
        pub fn init(reader: *Reader, length: u64) Error!Self {
            var self = Self{ .reader = reader, .length = length, .trie_start = 0, .trie_length = 0, .cand_start = 0, .cand_length = 0, .arena_start = 0, .arena_length = 0 };
            var header: [36]u8 = undefined;
            try self.read(0, &header);
            if (!std.mem.eql(u8, header[0..4], "NFST") or std.mem.readInt(u16, header[4..6], .little) != 1 or std.mem.readInt(u16, header[6..8], .little) != 0) return error.Corrupt;
            self.trie_start = std.mem.readInt(u32, header[12..16], .little);
            self.trie_length = std.mem.readInt(u32, header[16..20], .little);
            self.cand_start = std.mem.readInt(u32, header[20..24], .little);
            self.cand_length = std.mem.readInt(u32, header[24..28], .little);
            self.arena_start = std.mem.readInt(u32, header[28..32], .little);
            self.arena_length = std.mem.readInt(u32, header[32..36], .little);
            if (self.trie_start != header.len or self.trie_length < 6 or
                self.cand_start != self.trie_start + self.trie_length or
                self.arena_start != self.cand_start + self.cand_length or
                self.arena_start + self.arena_length != length) return error.Corrupt;
            return self;
        }
        pub fn lookup(self: *Self, key: []const u8, out: *Candidates) Error!void {
            out.count = 0;
            out.truncated = false;
            if (self.closed) return error.Io;
            if (key.len == 0 or key.len > max_key_bytes or !std.unicode.utf8ValidateSlice(key)) return error.InvalidKey;
            var result: Candidates = .{};
            var node: u64 = 0;
            var key_pos: usize = 0;
            // Each child must advance in the BFS-encoded trie and consume a
            // byte, bounding traversal even for malformed input.
            while (true) {
                if (!fits(node, 1, self.trie_length)) return error.Corrupt;
                const edge_len = try self.byte(self.trie_start + node);
                const header_size: u64 = @as(u64, edge_len) + 6;
                if (!fits(node, header_size, self.trie_length)) return error.Corrupt;
                if (edge_len > key.len - key_pos) return;
                var edge: [255]u8 = undefined;
                try self.read(self.trie_start + node + 1, edge[0..edge_len]);
                if (!std.mem.eql(u8, edge[0..edge_len], key[key_pos..][0..edge_len])) return;
                key_pos += edge_len;
                const candidate_offset = try self.word(self.trie_start + node + 1 + edge_len);
                const child_count = try self.byte(self.trie_start + node + 5 + edge_len);
                const children = node + header_size;
                if (!fits(children, @as(u64, child_count) * 4, self.trie_length)) return error.Corrupt;
                if (key_pos == key.len) {
                    if (candidate_offset == 0xffffffff) return;
                    if (!fits(candidate_offset, 1, self.cand_length)) return error.Corrupt;
                    const count = try self.byte(self.cand_start + candidate_offset);
                    if (!fits(@as(u64, candidate_offset) + 1, @as(u64, count) * 4, self.cand_length)) return error.Corrupt;
                    for (0..@min(count, max_candidates)) |i| {
                        const entry = try self.word(self.cand_start + candidate_offset + 1 + 4 * i);
                        const pos = entry & 0xffffff;
                        const n: u8 = @truncate(entry >> 24);
                        if (n == 0 or !fits(pos, n, self.arena_length)) return error.Corrupt;
                        try self.read(self.arena_start + pos, result.bytes[i][0..n]);
                        if (!std.unicode.utf8ValidateSlice(result.bytes[i][0..n])) return error.Corrupt;
                        result.lengths[i] = n;
                        result.count += 1;
                    }
                    result.truncated = count > max_candidates;
                    out.* = result;
                    return;
                }
                var next: ?u64 = null;
                // Copy the child table once. Alternating parent-pointer and
                // child-edge reads with one cache page otherwise reloads the
                // parent for every child on a large dictionary.
                var offsets: [255 * 4]u8 = undefined;
                try self.read(self.trie_start + children, offsets[0 .. @as(usize, child_count) * 4]);
                for (0..child_count) |i| {
                    const child = std.mem.readInt(u32, offsets[i * 4 ..][0..4], .little);
                    if (child <= node or !fits(child, 2, self.trie_length)) return error.Corrupt;
                    if (try self.byte(self.trie_start + child) == 0) return error.Corrupt;
                    if (try self.byte(self.trie_start + child + 1) == key[key_pos]) {
                        next = child;
                        break;
                    }
                }
                node = next orelse return;
            }
        }
    };
}
