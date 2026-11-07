//! Experimental synchronous bridge from a pinned paged NFST to the IME.
//! Candidate slices remain valid only until the next lookup. The conversion
//! engine copies them immediately. The caller must serialize use and keep the
//! underlying object pinned until the dictionary is invalidated.
const nfst = @import("../storage/nfst_reader.zig");

pub fn Adapter(comptime Reader: type) type {
    return struct {
        const Self = @This();
        dictionary: *nfst.Dictionary(Reader),
        candidates: nfst.Candidates = .{},
        failure: ?nfst.Error = null,
        truncated: bool = false,
        memo_enabled: bool = true,
        memo: [64]Memo = @splat(.{}),
        memo_count: usize = 0,
        memo_hits: usize = 0,
        const Memo = struct {
            key: [64]u8 = @splat(0),
            len: u8 = 0,
            found: bool = false,
        };

        pub fn beginConversion(self: *Self) void {
            self.failure = null;
            self.truncated = false;
            self.memo_count = 0;
            self.memo_hits = 0;
        }
        pub fn conversionError(self: *const Self) nfst.Error!void {
            if (self.failure) |err| return err;
        }
        /// Existence answers are scoped to one conversion and one pinned
        /// dictionary. A failed lookup is never inserted into the memo.
        pub fn contains(self: *Self, key: []const u8) bool {
            if (self.failure != null) return false;
            if (self.memo_enabled) for (self.memo[0..self.memo_count]) |*entry| {
                if (std.mem.eql(u8, entry.key[0..entry.len], key)) {
                    self.memo_hits += 1;
                    return entry.found;
                }
            };
            var out: [1][]const u8 = undefined;
            const found = self.lookup(key, &out) != 0;
            if (self.failure == null and self.memo_enabled and key.len <= 64 and self.memo_count < self.memo.len) {
                const entry = &self.memo[self.memo_count];
                @memcpy(entry.key[0..key.len], key);
                entry.len = @intCast(key.len);
                entry.found = found;
                self.memo_count += 1;
            }
            return found;
        }
        pub fn lookup(self: *Self, key: []const u8, out: [][]const u8) usize {
            if (self.failure != null) return 0;
            self.dictionary.lookup(key, &self.candidates) catch |err| {
                self.failure = err;
                return 0;
            };
            self.truncated = self.truncated or self.candidates.truncated;
            const count = @min(out.len, self.candidates.count);
            for (0..count) |i| out[i] = self.candidates.slice(i);
            return count;
        }
    };
}

const std = @import("std");
const state = @import("standard_ime.zig");
const document = @import("document.zig");
const Bytes = struct {
    bytes: []const u8,
    fail: bool = false,
    pub fn read(self: *@This(), offset: u64, out: []u8) error{Io}!usize {
        if (self.fail or offset > self.bytes.len or out.len > self.bytes.len - offset) return error.Io;
        @memcpy(out, self.bytes[@intCast(offset)..][0..out.len]);
        return out.len;
    }
};

test "paged IME preserves composition on read failure and copies candidates" {
    const bytes = @embedFile("fixtures/jisyo_s_nfst.bin");
    var reader = Bytes{ .bytes = bytes };
    var dict = try nfst.Dictionary(Bytes).init(&reader, bytes.len);
    var adapter = Adapter(Bytes){ .dictionary = &dict };
    var ime: state.State = .{};
    var doc: document.Document(512, 16, 512, 1, 64) = .{};
    for ("kanji") |c| try ime.key(&doc, &adapter, c);
    try ime.key(&doc, &adapter, ' ');
    try std.testing.expectEqualStrings("漢字", doc.preedit.slice());
    try ime.key(&doc, &adapter, ' ');
    try std.testing.expectEqualStrings("幹事", doc.preedit.slice());
    try ime.key(&doc, &adapter, '\n');
    try std.testing.expectEqualStrings("幹事", doc.slice());
    for ("nihon") |c| try ime.key(&doc, &adapter, c);
    // Force the next page fetch to fail while composition is active.
    dict.cache_valid = false;
    dict.root_cache_valid = false;
    reader.fail = true;
    try std.testing.expectError(error.Io, ime.key(&doc, &adapter, ' '));
    try std.testing.expectEqualStrings("幹事", doc.slice());
    try std.testing.expectEqualStrings("にほん", doc.preedit.slice());
    try std.testing.expect(!ime.converting);
    try std.testing.expectEqual(@as(usize, 0), ime.engine.segment_count);
    reader.fail = false;
    try std.testing.expectError(error.Io, ime.key(&doc, &adapter, ' '));
}

test "existence memo resets per conversion and never stores failed reads" {
    const bytes = @embedFile("fixtures/jisyo_s_nfst.bin");
    var reader = Bytes{ .bytes = bytes };
    var dict = try nfst.Dictionary(Bytes).init(&reader, bytes.len);
    var adapter = Adapter(Bytes){ .dictionary = &dict };
    adapter.beginConversion();
    try std.testing.expect(adapter.contains("かんじ"));
    const misses = dict.cache_misses;
    try std.testing.expect(adapter.contains("かんじ"));
    try std.testing.expectEqual(misses, dict.cache_misses);
    try std.testing.expectEqual(@as(usize, 1), adapter.memo_hits);
    adapter.beginConversion();
    try std.testing.expectEqual(@as(usize, 0), adapter.memo_count);
    dict.cache_valid = false;
    dict.root_cache_valid = false;
    reader.fail = true;
    try std.testing.expect(!adapter.contains("かんじ"));
    try std.testing.expectError(error.Io, adapter.conversionError());
    try std.testing.expectEqual(@as(usize, 0), adapter.memo_count);
    // A previous successful answer must not mask an invalidated reader.
    adapter.beginConversion();
    reader.fail = false;
    try std.testing.expect(!adapter.contains("かんじ"));
    try std.testing.expectError(error.Io, adapter.conversionError());
}

test "sliced paged conversion fails without publishing partial candidates" {
    const conv = @import("conv.zig");
    const bytes = @embedFile("fixtures/jisyo_s_nfst.bin");
    var reader = Bytes{ .bytes = bytes };
    var dict = try nfst.Dictionary(Bytes).init(&reader, bytes.len);
    var adapter = Adapter(Bytes){ .dictionary = &dict };
    var engine: conv.Engine = .{};
    var sliced: conv.SlicedConversion = .{};
    sliced.begin(&engine, &adapter, "かんじ");
    dict.root_cache_valid = false;
    dict.cache_valid = false;
    dict.victim_valid = false;
    reader.fail = true;
    var got_error = false;
    for (0..100) |_| {
        _ = sliced.step(&engine, &adapter, 1) catch |err| {
            try std.testing.expectEqual(error.Io, err);
            got_error = true;
            break;
        };
    }
    try std.testing.expect(got_error);
    try std.testing.expectEqual(@as(usize, 0), engine.segment_count);
    try std.testing.expectEqual(conv.SlicedConversion.Progress.cancelled, try sliced.step(&engine, &adapter, 1));
}
