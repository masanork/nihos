const std = @import("std");
const checkpoint = @import("checkpoint_model.zig");
const media = @import("model_media.zig");
const file_media = @import("file_media.zig");
const Backend = media.Media(32 * 4096);
const config = checkpoint.Config{ .leaf_pages = 2, .index_pages = 8 };

fn Meter(comptime B: type) type {
    return struct {
        const Self = @This();
        pub const capacity = B.capacity;
        backend: *B,
        bytes_read: usize = 0,
        deny_at: ?u64 = null,
        pub fn read(self: *Self, offset: u64, destination: []u8) error{Io}!void {
            if (self.deny_at) |limit| if (offset > limit or destination.len > limit - offset) return error.Io;
            self.bytes_read += destination.len;
            return self.backend.read(offset, destination);
        }
        pub fn write(self: *Self, offset: u64, data: []const u8) error{Io}!void {
            return self.backend.write(offset, data);
        }
        pub fn sync(self: *Self) error{Io}!void {
            return self.backend.sync();
        }
    };
}
const Device = Meter(Backend);
const Store = checkpoint.Store(Device, config);
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;

fn pattern(comptime n: usize, seed: u8) [n]u8 {
    @setEvalBranchQuota(n * 2 + 1000);
    var bytes: [n]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @truncate(i *% 17 +% seed);
    return bytes;
}
const old_a = pattern(5003, 0x31);
const old_b = pattern(4096, 0x42);
const new_a = pattern(6001, 0x53);
const new_b = pattern(4101, 0x64);

fn baseline(device: *Device) !void {
    var store = Store{};
    try store.format(device);
    try store.begin();
    try store.put(1, &old_a);
    try store.put(checkpoint.leaf_entries + 1, &old_b);
    try store.commit();
    device.backend.powerLoss();
    device.bytes_read = 0;
}
fn update(store: *Store) !void {
    try store.begin();
    try store.put(1, &new_a);
    try store.remove(checkpoint.leaf_entries + 1);
    try store.put(2, &new_b);
    try store.commit();
}
fn object(store: *Store, id: u32, expected: []const u8) !void {
    var buffer: [8192]u8 = undefined;
    try equal(expected.len, try store.read(id, 0, &buffer));
    try std.testing.expectEqualSlices(u8, expected, buffer[0..expected.len]);
}
fn state(store: *Store) !void {
    if (store.generation() == 2) {
        try object(store, 1, &old_a);
        try object(store, checkpoint.leaf_entries + 1, &old_b);
        try expectError(error.NotFound, store.get(2));
    } else {
        try equal(@as(u64, 3), store.generation());
        try object(store, 1, &new_a);
        try object(store, 2, &new_b);
        try expectError(error.NotFound, store.get(checkpoint.leaf_entries + 1));
    }
}
fn recover(store: *Store, device: *Device) !void {
    device.bytes_read = 0;
    device.deny_at = Store.payload_start * 4096;
    try store.recover(device);
    try expect(device.bytes_read <= Store.mount_limit_bytes);
    try equal(device.bytes_read, store.mount_bytes);
    device.deny_at = null;
}

test "paged checkpoint mounts metadata only and atomically spans multiple leaves" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    try baseline(&device);
    var store = Store{};
    try recover(&store, &device);
    try equal(@as(usize, 4 * 4096), store.mount_bytes);
    try update(&store);
    backend.powerLoss();
    var reopened = Store{};
    try recover(&reopened, &device);
    try state(&reopened);
    try equal(@as(usize, 6 * 4096), reopened.mount_bytes);
}

test "owner restores a pinned volume as a new crash-safe generation" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    try baseline(&device);
    var store = Store{};
    try recover(&store, &device);
    const pinned = try store.pin();
    const object_pin = try store.pinObject(1);
    try update(&store);
    const generation = store.generation();
    try expectError(error.InvalidReader, store.restore(object_pin));
    try store.restore(pinned);
    try equal(generation + 1, store.generation());
    try object(&store, 1, &old_a);
    try object(&store, checkpoint.leaf_entries + 1, &old_b);
    try expectError(error.NotFound, store.get(2));
    try store.release(pinned);
    try expectError(error.InvalidReader, store.restore(pinned));
    try store.release(object_pin);
    backend.powerLoss();
    var reopened = Store{};
    try recover(&reopened, &device);
    try equal(generation + 1, reopened.generation());
    try object(&reopened, 1, &old_a);
}

test "checkpoint publication survives every sector and barrier cut with bounded mount IO" {
    var base = Backend{};
    var initial = Device{ .backend = &base };
    try baseline(&initial);
    var cuts: usize = 0;
    var events: usize = 0;
    var max_mount: usize = 0;
    for ([_]media.Background{ .none, .alternating, .all }) |background| {
        for ([_]media.Order{ .ascending, .descending }) |order| {
            var clean = base;
            clean.background = background;
            clean.order = order;
            var device = Device{ .backend = &clean };
            var store = Store{};
            try recover(&store, &device);
            try update(&store);
            events = clean.events;
            try equal(@as(usize, 162), events);
            clean.powerLoss();
            var acknowledged = Store{};
            try recover(&acknowledged, &device);
            try equal(@as(u64, 3), acknowledged.generation());
            try state(&acknowledged);
            for (0..events) |event| {
                for ([_]usize{ 0, 1, 31, 255, 511, 512 }) |prefix| {
                    var broken = base;
                    broken.background = background;
                    broken.order = order;
                    broken.cut = .{ .event = event, .prefix = prefix };
                    var failing = Device{ .backend = &broken };
                    var interrupted = Store{};
                    try recover(&interrupted, &failing);
                    try expectError(error.Io, update(&interrupted));
                    try expectError(error.Faulted, interrupted.begin());
                    broken.powerLoss();
                    var recovered = Store{};
                    try recover(&recovered, &failing);
                    max_mount = @max(max_mount, recovered.mount_bytes);
                    state(&recovered) catch |err| {
                        std.debug.print("CHECKPOINT_COUNTEREXAMPLE event={d} prefix={d} background={s} order={s} recovered_generation={d} error={s}\n", .{
                            event, prefix, @tagName(background), @tagName(order), recovered.generation(), @errorName(err),
                        });
                        return err;
                    };
                    cuts += 1;
                }
            }
        }
    }
    try equal(@as(usize, 5832), cuts);
    std.debug.print("CHECKPOINT_CAMPAIGN events={d} crash_cases={d} acknowledged_cases=6 max_mount_bytes={d}\n", .{ events, cuts, max_mount });
}

test "payload integrity is deferred to read while damaged index pages reject a checkpoint" {
    var base = Backend{};
    var initial = Device{ .backend = &base };
    try baseline(&initial);
    var damaged = base;
    damaged.stable[Store.payload_start * 4096 + 17] ^= 1;
    damaged.powerLoss();
    var device = Device{ .backend = &damaged };
    var mounted = Store{};
    try recover(&mounted, &device);
    try equal(@as(u64, 2), mounted.generation());
    var bytes: [1]u8 = undefined;
    try expectError(error.Corrupt, mounted.read(1, 0, &bytes));
    try expectError(error.Faulted, mounted.begin());
    var bad_index = base;
    bad_index.stable[2 * 4096 + 17] ^= 1;
    bad_index.powerLoss();
    var other = Device{ .backend = &bad_index };
    var fallback = Store{};
    try recover(&fallback, &other);
    try equal(@as(u64, 1), fallback.generation());
    try expectError(error.NotFound, fallback.get(1));
}

test "fixed geometry bounds descriptor RAM independently of volume capacity" {
    const Small = checkpoint.Store(file_media.Media(1024 * 1024 * 1024), .{});
    const Large = checkpoint.Store(file_media.Media(16 * 1024 * 1024 * 1024), .{});
    try equal(@sizeOf(Small), @sizeOf(Large));
    try expect(@sizeOf(Large) <= 32 * 1024);
    try equal(@as(usize, 258 * 4096), Large.mount_limit_bytes);
    try equal(@as(u32, 640), Large.max_protected_index_pages);
    try expect(Large.index_pool_pages > Large.max_protected_index_pages);
    std.debug.print("CHECKPOINT_BUDGET state_bytes={d} max_objects={d} mount_limit_bytes={d} tail_replay_bytes=0\n", .{
        @sizeOf(Large), Large.max_objects, Large.mount_limit_bytes,
    });
}

test "metadata space admission and rollback do not overwrite a published leaf" {
    const TinyBackend = media.Media(12 * 4096);
    const Tiny = checkpoint.Store(TinyBackend, .{ .leaf_pages = 1, .index_pages = 2 });
    var backend = TinyBackend{};
    var store = Tiny{};
    try store.format(&backend);
    try store.begin();
    try store.put(1, "old");
    try store.commit();
    try store.begin();
    try store.put(1, "discarded");
    try store.rollback();
    try store.begin();
    try store.put(1, "new");
    try store.commit();
    try store.begin();
    const events = backend.events;
    try expectError(error.NoSpace, store.put(2, "full"));
    try equal(events, backend.events);
    try store.rollback();
    backend.powerLoss();
    var recovered = Tiny{};
    try recovered.recover(&backend);
    var bytes: [3]u8 = undefined;
    try equal(bytes.len, try recovered.read(1, 0, &bytes));
    try std.testing.expectEqualSlices(u8, "new", &bytes);
}

fn rootChecksum(backend: *Backend, slot: usize) void {
    const bytes = backend.cache[slot * 4096 ..][0..4096];
    std.mem.writeInt(u32, bytes[checkpoint.crc_offset..][0..4], std.hash.Crc32.hash(bytes[0..checkpoint.crc_offset]), .little);
    backend.stable = backend.cache;
}

test "checkpoint geometry and index bounds are validated before a leaf is read" {
    var base = Backend{};
    var initial = Device{ .backend = &base };
    try baseline(&initial);
    for ([_][2]u64{ .{ 16, 999 }, .{ 24, 999 }, .{ 32, 999 }, .{ 48, 999 }, .{ 64, 999 } }) |change| {
        var broken = base;
        std.mem.writeInt(u64, broken.cache[change[0]..][0..8], change[1], .little);
        rootChecksum(&broken, 0);
        var device = Device{ .backend = &broken };
        var recovered = Store{};
        try recover(&recovered, &device);
        try equal(@as(u64, 1), recovered.generation());
    }
    var device = Device{ .backend = &base };
    const Wrong = checkpoint.Store(Device, .{ .leaf_pages = 2, .index_pages = 9 });
    var wrong = Wrong{};
    try expectError(error.Corrupt, wrong.recover(&device));
}

test "index corruption after mount faults the instance and generations cannot wrap" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    try baseline(&device);
    var mounted = Store{};
    try recover(&mounted, &device);
    backend.cache[2 * 4096 + 33] ^= 1;
    try expectError(error.Corrupt, mounted.get(1));
    try expectError(error.Faulted, mounted.begin());
    backend.powerLoss();
    @memcpy(backend.cache[4096..8192], backend.cache[0..4096]);
    std.mem.writeInt(u64, backend.cache[4096 + 8 ..][0..8], std.math.maxInt(u64), .little);
    rootChecksum(&backend, 1);
    var exhausted = Store{};
    try recover(&exhausted, &device);
    try expectError(error.GenerationExhausted, exhausted.begin());
}
