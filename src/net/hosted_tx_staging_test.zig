const std = @import("std");
const staging = @import("hosted_tx_staging.zig");

const Cache = struct {
    fail_writeback: bool = false,
    fail_invalidate: bool = false,
    owned: bool = false,
    writeback_len: usize = 0,
    address: usize = 0,
    invalidate_count: usize = 0,
    pub fn writeback(self: *@This(), bytes: []const u8) bool {
        self.writeback_len = bytes.len;
        self.address = @intFromPtr(bytes.ptr);
        return !self.fail_writeback;
    }
    pub fn invalidateDescriptor(self: *@This()) bool {
        self.invalidate_count += 1;
        return !self.fail_invalidate;
    }
    pub fn descriptorOwned(self: *@This()) bool {
        return self.owned;
    }
};

test "long staging pads and owns aligned complete cache lines until completion" {
    var cache: Cache = .{};
    var buffer: staging.Staging = .{};
    const packet: [1254]u8 = @splat(0xa5);
    const result = try buffer.prepare(&packet, &cache);
    try std.testing.expectEqual(@as(usize, 1536), result.wire);
    try std.testing.expectEqual(@as(usize, 1536), cache.writeback_len);
    try std.testing.expectEqual(@as(usize, 0), cache.address % 64);
    try std.testing.expectEqualSlices(u8, &packet, buffer.bytes[0..packet.len]);
    try std.testing.expect(std.mem.allEqual(u8, buffer.bytes[packet.len..result.wire], 0));
    try std.testing.expectError(error.Busy, buffer.prepare(&packet, &cache));
    try buffer.complete(true, &cache);
    try std.testing.expectEqual(staging.State.idle, buffer.state);
    try std.testing.expectEqual(@as(usize, 1), cache.invalidate_count);
    _ = try buffer.prepare(&packet, &cache);
}

test "cache failure, retained descriptor and timeout quarantine the buffer" {
    const packet: [513]u8 = @splat(1);
    for (0..5) |mode| {
        var cache: Cache = .{ .fail_writeback = mode == 0, .fail_invalidate = mode == 1, .owned = mode == 2 };
        var buffer: staging.Staging = .{};
        if (mode == 0) {
            try std.testing.expectError(error.Cache, buffer.prepare(&packet, &cache));
        } else {
            _ = try buffer.prepare(&packet, &cache);
            if (mode == 1) try std.testing.expectError(error.Cache, buffer.complete(true, &cache)) else if (mode == 2)
                try std.testing.expectError(error.StillOwned, buffer.complete(true, &cache))
            else if (mode == 3) buffer.fail() else try std.testing.expectError(error.StillOwned, buffer.complete(false, &cache));
        }
        try std.testing.expectEqual(staging.State.retired, buffer.state);
        try std.testing.expectError(error.Retired, buffer.prepare(&packet, &cache));
    }
}
