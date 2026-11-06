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

        pub fn beginConversion(self: *Self) void {
            self.failure = null;
            self.truncated = false;
        }
        pub fn conversionError(self: *const Self) nfst.Error!void {
            if (self.failure) |err| return err;
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
    reader.fail = true;
    try std.testing.expectError(error.Io, ime.key(&doc, &adapter, ' '));
    try std.testing.expectEqualStrings("幹事", doc.slice());
    try std.testing.expectEqualStrings("にほん", doc.preedit.slice());
    try std.testing.expect(!ime.converting);
    try std.testing.expectEqual(@as(usize, 0), ime.engine.segment_count);
    reader.fail = false;
    try std.testing.expectError(error.Io, ime.key(&doc, &adapter, ' '));
}
