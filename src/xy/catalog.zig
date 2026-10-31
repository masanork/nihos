//! Read-only, offset-based ROM catalogue. No JSON parser or complete book in RAM.
const std = @import("std");
pub const Error = error{ InvalidPack, Range };
pub const Pack = struct {
    bytes: []const u8,
    count: u32,
    pub fn init(bytes: []const u8) Error!Pack {
        if (bytes.len < 64 or !std.mem.eql(u8, bytes[0..8], "XYREAD01") or read(bytes, 8) != 1 or read(bytes, 12) != bytes.len) return error.InvalidPack;
        const count = read(bytes, 16);
        if (count == 0 or count > 256 or read(bytes, 20) != 64 or 64 + @as(u64, count) * 36 > bytes.len) return error.InvalidPack;
        const pack = Pack{ .bytes = bytes, .count = count };
        _ = try pack.slice(read(bytes, 24), read(bytes, 28));
        _ = try pack.slice(read(bytes, 32), read(bytes, 36));
        for (0..count) |i| _ = try pack.entry(@intCast(i));
        return pack;
    }
    pub fn slice(self: Pack, offset: u32, len: u32) Error![]const u8 {
        if (offset > self.bytes.len or len > self.bytes.len - offset) return error.Range;
        return self.bytes[offset..][0..len];
    }
    pub fn font(self: Pack, style: u1) Error![]const u8 {
        const at: usize = 24 + @as(usize, style) * 8;
        return self.slice(read(self.bytes, at), read(self.bytes, at + 4));
    }
    pub fn entry(self: Pack, index: u32) Error!Entry {
        if (index >= self.count) return error.Range;
        const at: usize = 64 + @as(usize, index) * 36;
        const book = read(self.bytes, at);
        if (book >= 4) return error.Range;
        const count = read(self.bytes, at + 24);
        if (count > 65536) return error.Range;
        return .{ .book = book, .title = try self.slice(read(self.bytes, at + 4), read(self.bytes, at + 8)), .text = try self.slice(read(self.bytes, at + 12), read(self.bytes, at + 16)), .ruby = try self.slice(read(self.bytes, at + 20), count * 16), .credits = try self.slice(read(self.bytes, at + 28), read(self.bytes, at + 32)) };
    }
    pub fn chapter(self: Pack, book: u8, number: u16) Error!Entry {
        var seen: u32 = 0;
        for (0..self.count) |i| {
            const e = try self.entry(@intCast(i));
            if (e.book != book) continue;
            if (seen == number) return e;
            seen += 1;
        }
        return error.Range;
    }
    pub fn counts(self: Pack) Error![4]u16 {
        var result: [4]u16 = @splat(0);
        for (0..self.count) |i| result[(try self.entry(@intCast(i))).book] += 1;
        return result;
    }
};
pub const Entry = struct { book: u32, title: []const u8, text: []const u8, ruby: []const u8, credits: []const u8 };
pub inline fn read(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

test "ROM catalogue rejects truncated headers and out of bounds references" {
    try std.testing.expectError(error.InvalidPack, Pack.init("XYREAD01"));
    var bytes: [100]u8 = @splat(0);
    @memcpy(bytes[0..8], "XYREAD01");
    for ([_]struct { at: usize, value: u32 }{ .{ .at = 8, .value = 1 }, .{ .at = 12, .value = 100 }, .{ .at = 16, .value = 1 }, .{ .at = 20, .value = 64 } }) |v| std.mem.writeInt(u32, bytes[v.at..][0..4], v.value, .little);
    _ = try Pack.init(&bytes);
    std.mem.writeInt(u32, bytes[68..72], 101, .little);
    try std.testing.expectError(error.Range, Pack.init(&bytes));
}
