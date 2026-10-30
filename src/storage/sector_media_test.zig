const std = @import("std");
const adapter = @import("sector_media.zig");
const model = @import("model_media.zig");
const checkpoint = @import("checkpoint_model.zig");
const Owner = struct {
    pub const Lease = u32;
    backing: model.Media(40 * 4096) = .{},
    generation: u32 = 1,
    first: u64 = 8,
    sectors: u64 = 32 * 8,
    fail_sync: bool = false,
    calls: usize = 0,
    fn check(self: *@This(), lease: Lease, lba: u64) error{Io}!void {
        if (lease != self.generation or lba < self.first or lba - self.first >= self.sectors) return error.Io;
    }
    pub fn checkRange(self: *@This(), lease: Lease, first: u64, count: u64) error{Io}!void {
        if (lease != self.generation or first != self.first or count != self.sectors) return error.Io;
    }
    pub fn readSector(self: *@This(), lease: Lease, lba: u32, out: *[512]u8) error{Io}!void {
        try self.check(lease, lba);
        self.calls += 1;
        try self.backing.read(@as(u64, lba) * 512, out);
    }
    pub fn writeSector(self: *@This(), lease: Lease, lba: u32, bytes: *const [512]u8) error{Io}!void {
        try self.check(lease, lba);
        self.calls += 1;
        try self.backing.write(@as(u64, lba) * 512, bytes);
    }
    pub fn sync(self: *@This(), lease: Lease) error{Io}!void {
        if (lease != self.generation or self.fail_sync) return error.Io;
        try self.backing.sync();
    }
};
const Device = adapter.Media(Owner, 32 * 4096);
const Store = checkpoint.Store(Device, .{ .leaf_pages = 2, .index_pages = 8 });

test "checkpoint saves and recovers within an explicitly granted sector region" {
    var owner: Owner = .{};
    var device = try Device.init(&owner, 1, 8, 40 * 8);
    var store: Store = .{};
    try store.format(&device);
    try store.begin();
    try store.put(1, "editor text  ");
    try store.commit();
    owner.backing.powerLoss();
    var reopened = try Device.init(&owner, 1, 8, 40 * 8);
    var recovered: Store = .{};
    try recovered.recover(&reopened);
    var bytes: [64]u8 = undefined;
    const n = try recovered.read(1, 0, &bytes);
    try std.testing.expectEqualStrings("editor text  ", bytes[0..n]);
    for (owner.backing.stable[0 .. 8 * 512]) |byte| try std.testing.expectEqual(@as(u8, 0xff), byte);
    for (owner.backing.stable[(8 + 32 * 8) * 512 ..]) |byte| try std.testing.expectEqual(@as(u8, 0xff), byte);
}

test "invalid region and lost lease fail closed without touching a neighbor" {
    var owner: Owner = .{};
    try std.testing.expectError(error.Io, Device.init(&owner, 1, 9, 40 * 8));
    try std.testing.expectError(error.Io, Device.init(&owner, 1, 8, 8));
    try std.testing.expectEqual(@as(usize, 0), owner.calls);
    var device = try Device.init(&owner, 1, 8, 40 * 8);
    var bytes: [512]u8 = @splat(0x42);
    try std.testing.expectError(error.Io, device.write(Device.capacity, &bytes));
    try std.testing.expectError(error.Io, device.read(0, &bytes));
    try std.testing.expectEqual(@as(usize, 0), owner.calls);
    var stale = try Device.init(&owner, 1, 8, 40 * 8);
    owner.generation += 1;
    try std.testing.expectError(error.Io, stale.write(0, &bytes));
    try std.testing.expect(stale.faulted);
    try std.testing.expectEqual(@as(usize, 0), owner.calls);
}

test "partial reads span sectors and failed barriers poison the adapter" {
    var owner: Owner = .{};
    var device = try Device.init(&owner, 1, 8, 40 * 8);
    var bytes: [1024]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @truncate(i);
    try device.write(0, &bytes);
    var out: [23]u8 = undefined;
    try device.read(501, &out);
    try std.testing.expectEqualSlices(u8, bytes[501..524], &out);
    owner.fail_sync = true;
    try std.testing.expectError(error.Io, device.sync());
    try std.testing.expectError(error.Io, device.write(0, bytes[0..512]));
}

test "interrupted sector writes and barriers recover the old or complete new document" {
    var base: Owner = .{};
    var original = try Device.init(&base, 1, 8, 40 * 8);
    var formatted: Store = .{};
    try formatted.format(&original);
    try formatted.begin();
    try formatted.put(1, "old  ");
    try formatted.commit();
    base.backing.powerLoss();
    var normal = base;
    normal.backing.background = .all;
    var ok_device = try Device.init(&normal, 1, 8, 40 * 8);
    var ok_store: Store = .{};
    try ok_store.recover(&ok_device);
    try ok_store.begin();
    try ok_store.put(1, "new  ");
    try ok_store.commit();
    const events = normal.backing.events;
    try std.testing.expect(events > 0);
    normal.backing.powerLoss();
    var acknowledged_device = try Device.init(&normal, 1, 8, 40 * 8);
    var acknowledged: Store = .{};
    try acknowledged.recover(&acknowledged_device);
    var result: [64]u8 = undefined;
    const len = try acknowledged.read(1, 0, &result);
    try std.testing.expectEqualStrings("new  ", result[0..len]);
    for (0..events) |event| for ([_]usize{ 0, 31, 512 }) |prefix| {
        var interrupted = base;
        interrupted.backing.background = .all;
        interrupted.backing.cut = .{ .event = event, .prefix = prefix };
        var writing_device = try Device.init(&interrupted, 1, 8, 40 * 8);
        var writing: Store = .{};
        try writing.recover(&writing_device);
        try writing.begin();
        const put = writing.put(1, "new  ");
        if (put) |_| {
            try std.testing.expectError(error.Io, writing.commit());
        } else |err| try std.testing.expectEqual(error.Io, err);
        try std.testing.expect(writing_device.faulted);
        interrupted.backing.powerLoss();
        var recovering_device = try Device.init(&interrupted, 1, 8, 40 * 8);
        var recovered: Store = .{};
        try recovered.recover(&recovering_device);
        const actual = try recovered.read(1, 0, &result);
        try std.testing.expect(std.mem.eql(u8, result[0..actual], "old  ") or std.mem.eql(u8, result[0..actual], "new  "));
        for (interrupted.backing.stable[0 .. 8 * 512]) |byte| try std.testing.expectEqual(@as(u8, 0xff), byte);
        for (interrupted.backing.stable[(8 + 32 * 8) * 512 ..]) |byte| try std.testing.expectEqual(@as(u8, 0xff), byte);
    };
}
