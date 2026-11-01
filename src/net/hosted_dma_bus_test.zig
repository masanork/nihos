const std = @import("std");
const adapter = @import("hosted_dma_bus.zig");
const Short = struct {
    prepared: usize = 0,
    finished: usize = 0,
    fail_finish: bool = false,
    pub fn prepareDma(self: *@This(), _: bool, _: []const u8, length: usize) ?u32 {
        self.prepared = length;
        return 0x4ff00000;
    }
    pub fn finishDma(self: *@This(), _: bool, destination: []u8) bool {
        self.finished += 1;
        @memset(destination, 0x42);
        return !self.fail_finish;
    }
};
const Cache = struct {
    pub fn address(_: *@This(), _: anytype) ?u32 {
        return 0x4ff10000;
    }
    pub fn writeback(_: *@This(), _: usize, _: usize) bool {
        return true;
    }
    pub fn invalidate(_: *@This(), _: usize, _: usize) bool {
        return true;
    }
    pub fn fence(_: *@This()) void {}
};

test "short register reads and long writes use separate descriptors in order" {
    var buffer: adapter.Buffer = .{};
    var bus: adapter.Bus(Short, Cache) = .{ .short = .{}, .buffer = &buffer, .cache = .{} };
    var credit: [4]u8 = @splat(0);
    try std.testing.expectEqual(@as(?u32, 0x4ff00000), bus.prepareDma(false, &.{}, 4));
    try std.testing.expect(bus.finishDma(false, &credit));
    try std.testing.expect(std.mem.allEqual(u8, &credit, 0x42));
    const bytes: [1536]u8 = @splat(0x5a);
    try std.testing.expectEqual(@as(?u32, 0x4ff10000), bus.prepareDma(true, &bytes, bytes.len));
    try std.testing.expectEqual(@as(usize, 4), bus.short.prepared);
    try std.testing.expectEqual(@as(?u32, null), bus.prepareDma(false, &.{}, 4));
    buffer.descriptor[0] &= ~(@as(u32, 1) << 31);
    try std.testing.expect(bus.finishDma(true, &.{}));
    try std.testing.expectEqual(adapter.Active.none, bus.active);
    try std.testing.expectEqual(@as(usize, 1), bus.short.finished);
    try std.testing.expectEqualSlices(u8, &bytes, &buffer.data);
    try std.testing.expectEqual(@as(?u32, 0x4ff00000), bus.prepareDma(false, &.{}, 4));
}

test "short failure or retained long descriptor quarantines both routes" {
    for ([_]bool{ false, true }) |long| {
        var buffer: adapter.Buffer = .{};
        var bus: adapter.Bus(Short, Cache) = .{ .short = .{ .fail_finish = true }, .buffer = &buffer, .cache = .{} };
        const bytes: [1024]u8 = @splat(1);
        try std.testing.expect(bus.prepareDma(true, if (long) &bytes else bytes[0..4], if (long) 1024 else 4) != null);
        try std.testing.expect(!bus.finishDma(true, &.{}));
        try std.testing.expectEqual(adapter.Active.retired, bus.active);
        try std.testing.expectEqual(@as(?u32, null), bus.prepareDma(false, &.{}, 4));
        try std.testing.expectEqual(@as(?u32, null), bus.prepareDma(true, &bytes, 1024));
    }
}

test "unsupported long reads and partial source leave DMA untouched" {
    var buffer: adapter.Buffer = .{};
    var bus: adapter.Bus(Short, Cache) = .{ .short = .{}, .buffer = &buffer, .cache = .{} };
    try std.testing.expectEqual(@as(?u32, null), bus.prepareDma(false, &.{}, 1024));
    try std.testing.expectEqual(@as(?u32, null), bus.prepareDma(true, "abc", 1024));
    try std.testing.expectEqual(@as(?u32, null), bus.prepareDma(true, "abc", 4));
    try std.testing.expectEqual(@as(?u32, null), bus.prepareDma(true, "abc", 3));
    try std.testing.expectEqual(@as(?u32, null), bus.prepareDma(false, "abcd", 4));
    try std.testing.expectEqual(adapter.Active.none, bus.active);
    try std.testing.expectEqual(@as(usize, 0), bus.short.prepared);
}
