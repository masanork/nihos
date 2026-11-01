const std = @import("std");
const adapter = @import("hosted_long_cache.zig");
const Ops = struct {
    enabled: bool = true,
    status: i32 = 0,
    calls: usize = 0,
    fences: usize = 0,
    restores: usize = 0,
    masked_during_cache: bool = false,
    address: u32 = 0,
    length: u32 = 0,
    invalidated: bool = false,
    pub fn mask(self: *@This()) u32 {
        const previous: u32 = if (self.enabled) 8 else 0;
        self.enabled = false;
        return previous;
    }
    pub fn restore(self: *@This(), previous: u32) void {
        self.restores += 1;
        self.enabled = previous & 8 != 0;
    }
    pub fn fence(self: *@This()) void {
        self.fences += 1;
    }
    pub fn cache(self: *@This(), addr: u32, length: u32, invalidate: bool) i32 {
        self.calls += 1;
        self.masked_during_cache = !self.enabled;
        self.address = addr;
        self.length = length;
        self.invalidated = invalidate;
        return self.status;
    }
};

test "cache ABI range and interrupt state survive success and ROM failure" {
    for ([_]bool{ false, true }) |enabled| {
        for ([_]i32{ 0, -1 }) |status| {
            var cache: adapter.Adapter(Ops) = .{ .ops = .{ .enabled = enabled, .status = status } };
            try std.testing.expectEqual(status == 0, cache.writeback(0x4ff10000, 1536));
            try std.testing.expectEqual(enabled, cache.ops.enabled);
            try std.testing.expect(cache.ops.masked_during_cache);
            try std.testing.expectEqual(@as(u32, 0x4ff10000), cache.ops.address);
            try std.testing.expectEqual(@as(u32, 1536), cache.ops.length);
            try std.testing.expect(!cache.ops.invalidated);
            try std.testing.expectEqual(@as(usize, 2), cache.ops.fences);
            try std.testing.expectEqual(@as(usize, 1), cache.ops.restores);
            try std.testing.expectEqual(status == 0, cache.invalidate(0x4ff11000, 64));
            try std.testing.expect(cache.ops.invalidated);
            try std.testing.expectEqual(enabled, cache.ops.enabled);
        }
    }
}

test "invalid cache ranges do not change interrupt state or enter ROM" {
    var cache: adapter.Adapter(Ops) = .{ .ops = .{} };
    for ([_]usize{ 0, 63, 65, 1600 }) |length| try std.testing.expect(!cache.writeback(0x4ff10000, length));
    try std.testing.expect(!cache.invalidate(0x4ff10001, 64));
    try std.testing.expect(!cache.writeback(0xffffffc0, 128));
    try std.testing.expectEqual(@as(usize, 0), cache.ops.calls);
    try std.testing.expectEqual(@as(usize, 0), cache.ops.restores);
    try std.testing.expect(cache.ops.enabled);
}
