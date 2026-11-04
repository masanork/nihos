const std = @import("std");
const dma = @import("hosted_long_dma.zig");
const storage = @import("hosted_long_storage.zig");
const Fake = struct {
    pub const Lease = struct { generation: u32 };
    data: dma.Buffer = .{},
    available: bool = true,
    malformed: bool = false,
    takes: u32 = 0,
    resolves: u32 = 0,
    pub fn take(self: *@This(), owner: u32, size: usize) ?Lease {
        if (!self.available) return null;
        if (owner != storage.owner_id or size != storage.bytes) return null;
        self.takes += 1;
        return .{ .generation = self.takes };
    }
    pub fn resolve(self: *@This(), lease: Lease) ?*dma.Buffer {
        self.resolves += 1;
        if (self.malformed or lease.generation == 0) return null;
        return &self.data;
    }
};

test "reservation initializes one stable DMA-capable buffer only once" {
    var pool: Fake = .{};
    @memset(std.mem.asBytes(&pool.data), 0xa5);
    var owner: storage.Owner(Fake) = .{};
    try owner.reserve(&pool);
    const buffer = owner.buffer().?;
    try std.testing.expectEqual(@intFromPtr(&pool.data), @intFromPtr(buffer));
    try std.testing.expectEqual(dma.State.idle, buffer.state);
    try std.testing.expect(std.mem.allEqual(u8, &buffer.data, 0));
    buffer.data[0] = 0x42;
    try std.testing.expectError(error.AlreadyReserved, owner.reserve(&pool));
    try std.testing.expectEqual(@as(u8, 0x42), buffer.data[0]);
    try std.testing.expectEqual(@as(u32, 1), pool.takes);
}

test "unavailable storage can be retried without retaining a fake lease" {
    var pool: Fake = .{ .available = false };
    var owner: storage.Owner(Fake) = .{};
    try std.testing.expectError(error.NoStorage, owner.reserve(&pool));
    try std.testing.expectEqual(storage.State.empty, owner.state);
    try std.testing.expect(owner.lease == null and owner.buffer() == null);
    pool.available = true;
    try owner.reserve(&pool);
    try std.testing.expect(owner.buffer() != null);
}

test "malformed lease remains reserved and cannot be retried" {
    var pool: Fake = .{ .malformed = true };
    var owner: storage.Owner(Fake) = .{};
    try std.testing.expectError(error.InvalidLease, owner.reserve(&pool));
    try std.testing.expectEqual(storage.State.quarantined, owner.state);
    try std.testing.expect(owner.lease != null and owner.buffer() == null);
    pool.malformed = false;
    try std.testing.expectError(error.Quarantined, owner.reserve(&pool));
    try std.testing.expectEqual(@as(u32, 1), pool.takes);
}

test "ambiguous DMA is retained without erasing or reinitializing" {
    var pool: Fake = .{};
    var owner: storage.Owner(Fake) = .{};
    try owner.reserve(&pool);
    const buffer = owner.buffer().?;
    buffer.state = .prepared;
    buffer.data[3] = 0x9a;
    owner.retire();
    try std.testing.expectEqual(dma.State.retired, buffer.state);
    try std.testing.expectEqual(@as(u8, 0x9a), buffer.data[3]);
    try std.testing.expect(owner.buffer() == null and owner.lease != null);
    try std.testing.expectError(error.Quarantined, owner.reserve(&pool));
}

test "externally retired buffer cannot be handed out again" {
    var pool: Fake = .{};
    var owner: storage.Owner(Fake) = .{};
    try owner.reserve(&pool);
    owner.buffer().?.retire();
    try std.testing.expect(owner.buffer() == null);
    try std.testing.expectEqual(storage.State.quarantined, owner.state);
    try std.testing.expectError(error.Quarantined, owner.reserve(&pool));
}

test "in-flight buffer is not handed out for another operation" {
    var pool: Fake = .{};
    var owner: storage.Owner(Fake) = .{};
    try owner.reserve(&pool);
    const backing = owner.buffer().?;
    backing.state = .prepared;
    try std.testing.expect(owner.buffer() == null);
    try std.testing.expectEqual(storage.State.held, owner.state);
    backing.state = .idle;
    try std.testing.expectEqual(@intFromPtr(backing), @intFromPtr(owner.buffer().?));
}
