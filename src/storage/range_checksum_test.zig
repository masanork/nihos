const std = @import("std");
const model = @import("checkpoint_model.zig");
const media = @import("model_media.zig");
const file_media = @import("file_media.zig");
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;
const page = model.page_bytes;

fn Meter(comptime B: type) type {
    return struct {
        pub const capacity = B.capacity;
        backend: *B,
        bytes_read: usize = 0,
        read_limit: ?usize = null,
        fail_at: ?u64 = null,
        pub fn read(self: *@This(), offset: u64, destination: []u8) error{Io}!void {
            if (self.fail_at) |bad| if (offset == bad) return error.Io;
            if (self.read_limit) |limit| if (self.bytes_read > limit or destination.len > limit - self.bytes_read) return error.Io;
            self.bytes_read += destination.len;
            return self.backend.read(offset, destination);
        }
        pub fn write(self: *@This(), offset: u64, bytes: []const u8) error{Io}!void {
            return self.backend.write(offset, bytes);
        }
        pub fn sync(self: *@This()) error{Io}!void {
            return self.backend.sync();
        }
    };
}
const Backend = media.Media(64 * page);
const Device = Meter(Backend);
const Store = model.Store(Device, .{ .leaf_pages = 1, .index_pages = 4 });
const length = 70 * 1024 + 1;
fn value(index: usize) u8 {
    return @truncate(index *% 17 +% 0x31);
}
const payload: [length]u8 = bytes: {
    @setEvalBranchQuota(length * 2);
    var result: [length]u8 = undefined;
    for (&result, 0..) |*byte, i| byte.* = value(i);
    break :bytes result;
};
fn seed(device: *Device) !void {
    var store = Store{};
    try store.format(device);
    try store.begin();
    try store.put(1, &payload);
    try store.put(2, "same leaf");
    try store.commit();
    device.backend.powerLoss();
}
fn tableChecksum(backend: *Backend, offset: usize) void {
    const bytes = backend.stable[offset..][0..page];
    std.mem.writeInt(u32, bytes[model.crc_offset..][0..4], std.hash.Crc32.hash(bytes[0..model.crc_offset]), .little);
    backend.powerLoss();
}

test "partial reads charge touched pages only and leave neighboring leaf entries intact" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    try seed(&device);
    var store = Store{};
    try store.recover(&device);
    var buffer: [777]u8 = undefined;
    for ([_]u64{ 0, 4095, 4096, length - 1, length, std.math.maxInt(u64) }) |offset| {
        device.bytes_read = 0;
        const n: usize = if (offset < length) @intCast(@min(buffer.len, length - offset)) else 0;
        const touched = if (n == 0) 0 else (offset % page + n + page - 1) / page;
        const limit: usize = @intCast((1 + touched + @intFromBool(n != 0)) * page);
        device.read_limit = limit;
        try equal(n, try store.read(1, offset, &buffer));
        try equal(limit, device.bytes_read);
        for (buffer[0..n], 0..) |byte, i| try equal(value(@intCast(offset + i)), byte);
    }
    device.bytes_read = 0;
    device.read_limit = page;
    try equal(@as(usize, 0), try store.read(1, 0, buffer[0..0]));
    try equal(@as(usize, page), device.bytes_read);
    device.read_limit = null;
    var neighbor: [9]u8 = undefined;
    try equal(neighbor.len, try store.read(2, 0, &neighbor));
    try std.testing.expectEqualSlices(u8, "same leaf", &neighbor);
    device.bytes_read = 0;
    try store.verify(1);
    try equal(@as(usize, (1 + 18 + 1) * page), device.bytes_read);
}

test "unread corruption stays cold until touched or scrubbed and bad bytes are not copied" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    try seed(&device);
    const first = Store.payload_start * page;
    backend.stable[first + 17 * page + 1] ^= 1;
    backend.powerLoss();
    var store = Store{};
    try store.recover(&device);
    var byte: [1]u8 = @splat(0xee);
    device.bytes_read = 0;
    device.read_limit = 3 * page;
    try equal(@as(usize, 1), try store.read(1, 0, &byte));
    try equal(value(0), byte[0]);
    byte[0] = 0xee;
    device.bytes_read = 0;
    try expectError(error.Corrupt, store.read(1, 17 * page, &byte));
    try equal(@as(u8, 0xee), byte[0]);
    try expectError(error.Faulted, store.begin());
    device.read_limit = null;
    var scrubber = Store{};
    try scrubber.recover(&device);
    try expectError(error.Corrupt, scrubber.verify(1));
}

test "checksum pages validate CRC extent identity length and ordinal before payload output" {
    var base = Backend{};
    var initial = Device{ .backend = &base };
    try seed(&initial);
    const offset = (Store.payload_start + model.dataPages(length)) * page;
    // Header changes have valid CRCs, so identity checks must reject them.
    for ([_]usize{ 0, 4, 8, 16, 24, model.crc_offset }) |field| {
        var backend = base;
        backend.stable[offset + field] ^= 1;
        if (field != model.crc_offset) tableChecksum(&backend, offset) else backend.powerLoss();
        var device = Device{ .backend = &backend };
        var store = Store{};
        try store.recover(&device);
        var byte: [1]u8 = @splat(0xee);
        try expectError(error.Corrupt, store.read(1, 0, &byte));
        try equal(@as(u8, 0xee), byte[0]);
        try expectError(error.Faulted, store.verify(1));
    }
}

test "range I/O failure faults the transaction and a crossing read exposes only verified prefix" {
    var base = Backend{};
    var initial = Device{ .backend = &base };
    try seed(&initial);
    for ([_]u64{ Store.payload_start, Store.payload_start + model.dataPages(length) }) |bad| {
        var device = Device{ .backend = &base };
        var store = Store{};
        try store.recover(&device);
        try store.begin();
        device.fail_at = bad * page;
        var byte: [1]u8 = @splat(0xee);
        try expectError(error.Io, store.read(1, 0, &byte));
        try equal(@as(u8, 0xee), byte[0]);
        try expectError(error.Faulted, store.commit());
    }
    base.stable[(Store.payload_start + 1) * page] ^= 1;
    base.powerLoss();
    var device = Device{ .backend = &base };
    var store = Store{};
    try store.recover(&device);
    var crossing: [2]u8 = @splat(0xee);
    try expectError(error.Corrupt, store.read(1, page - 1, &crossing));
    try equal(value(page - 1), crossing[0]);
    try equal(@as(u8, 0xee), crossing[1]);
}

test "two checksum tables cover an object above four MiB with bounded crossing IO" {
    const File = file_media.Media(1040 * page);
    const Metered = Meter(File);
    const Large = model.Store(Metered, .{ .leaf_pages = 1, .index_pages = 4 });
    const big_length = model.checksums_per_page * page + 1;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.testing.io;
    {
        const file = try dir.dir.createFile(io, "large", .{ .read = true, .exclusive = true });
        defer file.close(io);
        try file.setLength(io, File.capacity);
        const blank: [2 * page]u8 = @splat(0xff);
        try file.writePositionalAll(io, &blank, 0);
        try file.sync(io);
    }
    var file = try File.open(io, dir.dir, "large");
    defer file.close();
    var device = Metered{ .backend = &file };
    var store = Large{};
    try store.format(&device);
    const data = try std.testing.allocator.alloc(u8, big_length);
    defer std.testing.allocator.free(data);
    for (data, 0..) |*byte, i| byte.* = value(i);
    try store.begin();
    try store.put(1, data);
    try store.commit();
    var reopened = Large{};
    try reopened.recover(&device);
    var crossing: [2]u8 = undefined;
    device.bytes_read = 0;
    device.read_limit = 5 * page;
    try equal(crossing.len, try reopened.read(1, big_length - 2, &crossing));
    try equal(@as(usize, 5 * page), device.bytes_read);
    try std.testing.expectEqualSlices(u8, data[big_length - 2 ..], &crossing);
    device.bytes_read = 0;
    device.read_limit = 3 * page;
    try equal(@as(usize, 1), try reopened.read(1, 0, crossing[0..1]));
    try equal(@as(usize, 3 * page), device.bytes_read);
    std.debug.print("RANGE_CHECKSUM_IO object_bytes={d} single_byte_bytes={d} crossing_table_bytes={d} checksum_pages=2\n", .{
        big_length, 3 * page, 5 * page,
    });
}

test "checksum footprint admission is side effect free and old format is rejected without writes" {
    const TinyBackend = media.Media(6 * page);
    const Tiny = model.Store(TinyBackend, .{ .leaf_pages = 1, .index_pages = 1 });
    var backend = TinyBackend{};
    var store = Tiny{};
    try store.format(&backend);
    try store.begin();
    const data: [2 * page + 1]u8 = @splat(0x31);
    const events = backend.events;
    try expectError(error.NoSpace, store.put(1, &data));
    try equal(events, backend.events);
    try store.rollback();
    // The only valid root is generation 1 in slot 1.
    std.mem.writeInt(u32, backend.cache[page + 4 ..][0..4], 1, .little);
    const root = backend.cache[page..][0..page];
    std.mem.writeInt(u32, root[model.crc_offset..][0..4], std.hash.Crc32.hash(root[0..model.crc_offset]), .little);
    backend.stable = backend.cache;
    backend.powerLoss();
    var reopened = Tiny{};
    try expectError(error.Corrupt, reopened.recover(&backend));
    try equal(@as(usize, 0), backend.events);
}
