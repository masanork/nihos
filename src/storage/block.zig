//! Synchronous read-only 512-byte sector interface. Caller owns backend lifetime
//! and serialization; subregions cannot escape the parent device/partition.
const std = @import("std");
pub const Sector = [512]u8;
pub const Error = error{ InvalidRange, Io };

pub fn Reader(comptime Backend: type) type {
    return struct {
        backend: *Backend,
        start: u64,
        count: u64,
        const Self = @This();

        pub fn init(backend: *Backend, sectors: u64) Error!Self {
            if (sectors == 0 or sectors > @as(u64, 1) << 32) return error.InvalidRange;
            return .{ .backend = backend, .start = 0, .count = sectors };
        }

        pub fn region(self: Self, start: u64, count: u64) Error!Self {
            if (count == 0 or start >= self.count or count > self.count - start) return error.InvalidRange;
            return .{ .backend = self.backend, .start = self.start + start, .count = count };
        }

        pub fn read(self: Self, lba: u64, destination: *Sector) Error!void {
            if (lba >= self.count) return error.InvalidRange;
            self.backend.readSector(@intCast(self.start + lba), destination) catch return error.Io;
        }
    };
}

const Mock = struct {
    calls: u32 = 0,
    last: u32 = 0,
    failed: bool = false,
    pub fn readSector(self: *@This(), lba: u32, destination: *Sector) error{Failed}!void {
        self.calls += 1;
        self.last = lba;
        if (self.failed) return error.Failed;
        destination.* = @splat(@truncate(lba));
    }
};

test "nested block regions enforce bounds before backend access" {
    var backend = Mock{};
    const device = try Reader(Mock).init(&backend, 100);
    const partition = try device.region(10, 20);
    const nested = try partition.region(5, 2);
    var buffer: Sector = undefined;
    try nested.read(1, &buffer);
    try std.testing.expectEqual(@as(u32, 16), backend.last);
    try std.testing.expectEqual(@as(u8, 16), buffer[511]);
    try std.testing.expectError(error.InvalidRange, nested.read(2, &buffer));
    try std.testing.expectError(error.InvalidRange, partition.region(19, 2));
    try std.testing.expectError(error.InvalidRange, partition.region(0, 0));
    try std.testing.expectEqual(@as(u32, 1), backend.calls);
    backend.failed = true;
    try std.testing.expectError(error.Io, nested.read(0, &buffer));
}

test "block interface handles the last sector of a 2 TiB device" {
    var backend = Mock{};
    const device = try Reader(Mock).init(&backend, @as(u64, 1) << 32);
    const last = try device.region(0xffff_ffff, 1);
    var buffer: Sector = undefined;
    try last.read(0, &buffer);
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), backend.last);
    try std.testing.expectError(error.InvalidRange, device.region(0xffff_ffff, 2));
    try std.testing.expectError(error.InvalidRange, Reader(Mock).init(&backend, 0));
    try std.testing.expectError(error.InvalidRange, Reader(Mock).init(&backend, (@as(u64, 1) << 32) + 1));
}
