//! Exact DCS packet lengths with bounded, injected FIFO waits.
const std = @import("std");
pub fn send(io: anytype, command: u8, parameters: []const u8) !void {
    if (parameters.len > 128) return error.InvalidPacket;
    const size = parameters.len + 1;
    if (size > 2) {
        var position: usize = 0;
        while (position < size) {
            var word: u32 = 0;
            for (0..@min(4, size - position)) |index| {
                const byte = if (position + index == 0) command else parameters[position + index - 1];
                word |= @as(u32, byte) << @intCast(index * 8);
            }
            try io.wait(1);
            io.payload(word);
            position += @min(4, size - position);
        }
        try io.wait(2);
        io.header(0x39, @intCast(size & 255), @intCast(size >> 8));
    } else {
        try io.wait(2);
        io.header(if (size == 1) 0x05 else 0x15, command, if (size == 1) 0 else parameters[0]);
    }
    try io.wait(4);
}
const Model = struct {
    words: [33]u32 = @splat(0),
    count: usize = 0,
    hdr: [3]u32 = @splat(0),
    fail_mask: u32 = 0,
    pub fn wait(self: *@This(), mask: u32) error{Timeout}!void {
        if (self.fail_mask == mask) return error.Timeout;
    }
    pub fn payload(self: *@This(), word: u32) void {
        self.words[self.count] = word;
        self.count += 1;
    }
    pub fn header(self: *@This(), kind: u32, low: u32, high: u32) void {
        self.hdr = .{ kind, low, high };
    }
};
test "short and padded long DCS writes preserve exact byte counts" {
    var model = Model{};
    try send(&model, 0x11, &.{});
    try std.testing.expectEqualDeep([3]u32{ 0x05, 0x11, 0 }, model.hdr);
    try send(&model, 0x36, &.{0x20});
    try std.testing.expectEqualDeep([3]u32{ 0x15, 0x36, 0x20 }, model.hdr);
    try send(&model, 0xa3, &.{ 1, 2, 3, 4 });
    try std.testing.expectEqualDeep([3]u32{ 0x39, 5, 0 }, model.hdr);
    try std.testing.expectEqual(@as(u32, 0x030201a3), model.words[0]);
    try std.testing.expectEqual(@as(u32, 4), model.words[1]);
    var maximum = Model{};
    var parameters: [128]u8 = @splat(0);
    for (&parameters, 0..) |*byte, index| byte.* = @intCast(index);
    try send(&maximum, 0xa3, &parameters);
    try std.testing.expectEqual(@as(usize, 33), maximum.count);
    try std.testing.expectEqual(@as(u32, 127), maximum.words[32]);
    try std.testing.expectEqualDeep([3]u32{ 0x39, 129, 0 }, maximum.hdr);
    var timeout = Model{ .fail_mask = 1 };
    try std.testing.expectError(error.Timeout, send(&timeout, 0xa3, &.{ 1, 2 }));
    try std.testing.expectEqual(@as(usize, 0), timeout.count);
    var oversized: [129]u8 = @splat(0);
    try std.testing.expectError(error.InvalidPacket, send(&model, 0, &oversized));
}
