//! Owner-private write-through page cache. A hit never acknowledges a write.
const std = @import("std");
pub fn Cache(comptime Backing: type, comptime slots: usize, comptime pinned: usize) type {
    if (pinned >= slots) @compileError("cache needs payload slots");
    return struct {
        backing: Backing,
        pages: *[slots][4096]u8,
        tags: [slots]u32 = @splat(0),
        valid: [slots]bool = @splat(false),
        const Self = @This();
        fn slot(page: u32) usize {
            return if (page < pinned) page else pinned + (page - pinned) % (slots - pinned);
        }
        fn checkedPage(offset: u64, length: usize) error{Io}!u32 {
            if (length != 4096 or offset % 4096 != 0 or offset >= Backing.capacity or length > Backing.capacity - offset) return error.Io;
            return @intCast(offset / 4096);
        }
        pub fn read(self: *Self, offset: u64, out: []u8) error{Io}!void {
            const number = try checkedPage(offset, out.len);
            const at = slot(number);
            if (self.valid[at] and self.tags[at] == number) {
                @memcpy(out, &self.pages[at]);
                return;
            }
            try self.backing.read(offset, out);
            @memcpy(&self.pages[at], out);
            self.tags[at] = number;
            self.valid[at] = true;
        }
        pub fn write(self: *Self, offset: u64, data: []const u8) error{Io}!void {
            const number = try checkedPage(offset, data.len);
            const at = slot(number);
            self.valid[at] = false;
            try self.backing.write(offset, data);
            @memcpy(&self.pages[at], data);
            self.tags[at] = number;
            self.valid[at] = true;
        }
        pub fn sync(self: *Self) error{Io}!void {
            try self.backing.sync();
        }
    };
}

test "metadata stays hot across payload eviction and failed writes never populate the cache" {
    const Fake = struct {
        pub const capacity: u64 = 8 * 4096;
        media: [8][4096]u8 = @splat(@splat(0)),
        reads: u32 = 0,
        writes: u32 = 0,
        fail_read: bool = false,
        fail_write: bool = false,
        fail_sync: bool = false,
        pub fn read(self: *@This(), offset: u64, out: []u8) error{Io}!void {
            self.reads += 1;
            if (self.fail_read) return error.Io;
            @memcpy(out, &self.media[@intCast(offset / 4096)]);
        }
        pub fn write(self: *@This(), offset: u64, data: []const u8) error{Io}!void {
            self.writes += 1;
            const dest = &self.media[@intCast(offset / 4096)];
            if (self.fail_write) {
                @memcpy(dest[0..31], data[0..31]);
                return error.Io;
            }
            @memcpy(dest, data);
        }
        pub fn sync(self: *@This()) error{Io}!void {
            if (self.fail_sync) return error.Io;
        }
    };
    const Backend = struct {
        pub const capacity = Fake.capacity;
        device: *Fake,
        pub fn read(self: @This(), offset: u64, out: []u8) error{Io}!void {
            try self.device.read(offset, out);
        }
        pub fn write(self: @This(), offset: u64, data: []const u8) error{Io}!void {
            try self.device.write(offset, data);
        }
        pub fn sync(self: @This()) error{Io}!void {
            try self.device.sync();
        }
    };
    var device = Fake{};
    var memory: [4][4096]u8 = undefined;
    var cache = Cache(Backend, 4, 2){ .backing = .{ .device = &device }, .pages = &memory };
    var out: [4096]u8 = undefined;
    const data: [4096]u8 = @splat(0x7b);
    try cache.read(0, &out);
    try cache.read(4096, &out);
    for (2..8) |i| try cache.read(i * 4096, &out);
    const reads = device.reads;
    try cache.read(0, &out);
    try cache.read(4096, &out);
    try std.testing.expectEqual(reads, device.reads);
    device.fail_write = true;
    try std.testing.expectError(error.Io, cache.write(0, &data));
    try cache.read(0, &out);
    try std.testing.expectEqualSlices(u8, data[0..31], out[0..31]);
    for (out[31..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    device.fail_write = false;
    try cache.write(0, &data);
    try cache.read(0, &out);
    try std.testing.expectEqualSlices(u8, &data, &out);
    device.fail_read = true;
    try std.testing.expectError(error.Io, cache.read(2 * 4096, &out));
    device.fail_read = false;
    try cache.read(2 * 4096, &out);
    const calls = device.writes;
    try std.testing.expectError(error.Io, cache.write(1, &data));
    try std.testing.expectError(error.Io, cache.write(Fake.capacity, &data));
    try std.testing.expectEqual(calls, device.writes);
    device.fail_sync = true;
    try std.testing.expectError(error.Io, cache.sync());
}
