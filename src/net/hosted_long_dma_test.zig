const std = @import("std");
const dma = @import("hosted_long_dma.zig");

const Backend = struct {
    calls: usize = 0,
    address_calls: usize = 0,
    fail_at: usize = 0,
    addresses: [3]usize = @splat(0),
    lengths: [3]usize = @splat(0),
    pub fn address(self: *@This(), ptr: anytype) ?u32 {
        if (@intFromPtr(ptr) % 64 != 0) return null;
        const result: u32 = if (self.address_calls == 0) 0x4ff10000 else 0x4ff11000;
        self.address_calls += 1;
        return result;
    }
    fn operation(self: *@This(), addr: usize, length: usize) bool {
        self.addresses[self.calls] = addr;
        self.lengths[self.calls] = length;
        self.calls += 1;
        return self.calls != self.fail_at;
    }
    pub fn writeback(self: *@This(), addr: usize, length: usize) bool {
        return self.operation(addr, length);
    }
    pub fn invalidate(self: *@This(), addr: usize, length: usize) bool {
        return self.operation(addr, length);
    }
    pub fn fence(_: *@This()) void {}
};

test "descriptor and cache ranges match the actual long DMA buffer" {
    for ([_]usize{ 1024, 1536 }) |length| {
        var buffer: dma.Buffer = .{};
        var backend: Backend = .{};
        const bytes: [1536]u8 = @splat(0xa5);
        try std.testing.expectEqual(@as(?u32, 0x4ff11000), buffer.prepare(bytes[0..length], &backend));
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(&buffer.data) % 64);
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(&buffer.descriptor) % 64);
        try std.testing.expectEqual(@intFromPtr(&buffer.data), backend.addresses[0]);
        try std.testing.expectEqual(@intFromPtr(&buffer.descriptor), backend.addresses[1]);
        try std.testing.expectEqual(length, backend.lengths[0]);
        try std.testing.expectEqual(@as(usize, 64), backend.lengths[1]);
        try std.testing.expectEqual(@as(u32, @intCast(length)), buffer.descriptor[1]);
        try std.testing.expectEqual(@as(u32, 0x4ff10000), buffer.descriptor[2]);
        try std.testing.expectEqualSlices(u8, bytes[0..length], buffer.data[0..length]);
        try std.testing.expectEqual(@as(?u32, null), buffer.prepare(bytes[0..length], &backend));
        buffer.descriptor[0] &= ~(@as(u32, 1) << 31); // simulated DMA completion
        try std.testing.expect(buffer.finish(&backend));
        try std.testing.expectEqual(@intFromPtr(&buffer.descriptor), backend.addresses[2]);
        try std.testing.expectEqual(dma.State.idle, buffer.state);
    }
}

test "invalid transfer lengths leave storage idle and never touch cache" {
    var buffer: dma.Buffer = .{};
    var backend: Backend = .{};
    const bytes: [1536]u8 = @splat(0);
    for ([_]usize{ 0, 512, 1023, 1025, 1535 }) |length| {
        try std.testing.expectEqual(@as(?u32, null), buffer.prepare(bytes[0..length], &backend));
    }
    try std.testing.expectEqual(dma.State.idle, buffer.state);
    try std.testing.expectEqual(@as(usize, 0), backend.address_calls);
    try std.testing.expectEqual(@as(usize, 0), backend.calls);
}

test "cache failures, retained descriptor, error flag and timeout quarantine" {
    const bytes: [1024]u8 = @splat(0x5a);
    for (0..6) |failure| {
        var buffer: dma.Buffer = .{};
        var backend: Backend = .{ .fail_at = if (failure < 2) failure + 1 else if (failure == 2) 3 else 0 };
        if (failure < 2) {
            try std.testing.expectEqual(@as(?u32, null), buffer.prepare(&bytes, &backend));
        } else {
            try std.testing.expect(buffer.prepare(&bytes, &backend) != null);
            if (failure != 3) buffer.descriptor[0] &= ~(@as(u32, 1) << 31);
            if (failure == 4) buffer.descriptor[0] |= @as(u32, 1) << 30;
            if (failure == 5) buffer.retire() else try std.testing.expect(!buffer.finish(&backend));
        }
        try std.testing.expectEqual(dma.State.retired, buffer.state);
        try std.testing.expectEqual(@as(?u32, null), buffer.prepare(&bytes, &backend));
    }
}
