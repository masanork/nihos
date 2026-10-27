const std = @import("std");
const model = @import("cow_model.zig");
const media = @import("model_media.zig");
const Device = media.Media(12 * model.page_bytes);
const Store = model.Store(Device, 8);
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;

fn pattern(comptime n: usize, seed: u8) [n]u8 {
    @setEvalBranchQuota(n * 2 + 1000);
    var result: [n]u8 = undefined;
    for (&result, 0..) |*byte, i| byte.* = @truncate(i *% 17 +% seed);
    return result;
}
const old_a = pattern(5003, 0x31);
const old_b = pattern(4096, 0x42);
const new_a = pattern(6001, 0x53);
const new_c = pattern(4101, 0x64);

fn baseline(device: *Device) !void {
    var store = try Store.format(device);
    try store.begin();
    try store.put(1, &old_a);
    try store.put(2, &old_b);
    try store.commit();
    try equal(@as(u64, 2), store.generation());
    device.powerLoss();
}

fn update(store: *Store) !void {
    try store.begin();
    try store.put(1, &new_a);
    try store.remove(2);
    try store.put(3, &new_c);
    try store.commit();
}

fn object(store: anytype, id: u32, expected: []const u8) !void {
    var buffer: [777]u8 = undefined;
    var offset: usize = 0;
    while (offset < expected.len) {
        const n = try store.read(id, offset, &buffer);
        try expect(n != 0 and n <= expected.len - offset);
        try std.testing.expectEqualSlices(u8, expected[offset..][0..n], buffer[0..n]);
        offset += n;
    }
    try equal(@as(usize, 0), try store.read(id, offset, &buffer));
}

fn state(store: *Store, generation: u64) !void {
    var buffer: [1]u8 = undefined;
    try equal(generation, store.generation());
    if (generation == 2) {
        try object(store, 1, &old_a);
        try object(store, 2, &old_b);
        try expectError(error.NotFound, store.read(3, 0, &buffer));
    } else if (generation == 3) {
        try object(store, 1, &new_a);
        try object(store, 3, &new_c);
        try expectError(error.NotFound, store.read(2, 0, &buffer));
    } else return error.UnexpectedGeneration;
}

fn publishedRootsComplete(device: *const Device, recovered: *const Store) bool {
    for (0..2) |slot| {
        const page = device.stable[slot * model.page_bytes ..][0..model.page_bytes];
        if (std.mem.readInt(u32, page[0..4], .little) != model.magic or
            std.mem.readInt(u32, page[4..8], .little) != model.version or
            std.hash.Crc32.hash(page[0..model.checksum_offset]) !=
                std.mem.readInt(u32, page[model.checksum_offset..][0..4], .little)) continue;
        // The generated protocol must not leave a checksummed published root
        // whose payload forces recovery to discard it and select an older one.
        if (std.mem.readInt(u64, page[8..16], .little) > recovered.generation()) return false;
    }
    return true;
}

test "publication is atomic across replacement creation and deletion and durable after acknowledgement" {
    var device = Device{};
    try baseline(&device);
    var store = try Store.recover(&device);
    try store.begin();
    try store.put(1, &new_a);
    try state(&store, 2); // Pending payload does not change the committed view.
    try store.remove(2);
    try store.put(3, &new_c);
    try store.commit();
    device.powerLoss();
    var recovered = try Store.recover(&device);
    try state(&recovered, 3);
}

test "every write and sync event recovers an entire old or new generation under torn reordered writeback" {
    var base = Device{};
    try baseline(&base);
    var cuts: usize = 0;
    var acknowledgements: usize = 0;
    var operations: usize = 0;
    for ([_]media.Background{ .none, .alternating, .all }) |background| {
        for ([_]media.Order{ .ascending, .descending }) |order| {
            var clean = base;
            clean.background = background;
            clean.order = order;
            var normal = try Store.recover(&clean);
            try update(&normal);
            const count = clean.events;
            if (operations == 0) operations = count;
            try equal(operations, count);
            clean.powerLoss();
            var acknowledged = try Store.recover(&clean);
            try state(&acknowledged, 3);
            acknowledgements += 1;
            for (0..count) |event| {
                for ([_]usize{ 0, 1, 31, 255, 511, 512 }) |prefix| {
                    var broken = base;
                    broken.background = background;
                    broken.order = order;
                    broken.cut = .{ .event = event, .prefix = prefix };
                    var interrupted = try Store.recover(&broken);
                    try expectError(error.Io, update(&interrupted));
                    try expect(broken.tripped);
                    try expectError(error.Faulted, interrupted.begin());
                    broken.powerLoss();
                    var recovered = try Store.recover(&broken);
                    try state(&recovered, recovered.generation());
                    if (!publishedRootsComplete(&broken, &recovered)) {
                        std.debug.print("STORE_MODEL_COUNTEREXAMPLE background={s} order={s} event={d} prefix={d} recovered={d}\n", .{
                            @tagName(background), @tagName(order), event, prefix, recovered.generation(),
                        });
                        return error.DanglingPublishedRoot;
                    }
                    cuts += 1;
                }
            }
        }
    }
    try equal(@as(usize, 82), operations);
    try equal(@as(usize, 2952), cuts);
    try equal(@as(usize, 6), acknowledgements);
    std.debug.print("STORE_MODEL_CAMPAIGN events={d} crash_cases={d} acknowledged_cases={d}\n", .{ operations, cuts, acknowledgements });
}

test "negative control detects sync that persists data but omits the locating root" {
    var device = Device{};
    try baseline(&device);
    device.omit_root_sync = true;
    var liar = try Store.recover(&device);
    try update(&liar); // The deliberately broken backend acknowledges gen 3.
    try equal(@as(u64, 3), liar.generation());
    device.powerLoss();
    var recovered = try Store.recover(&device);
    try state(&recovered, 2); // Acknowledged gen 3 was lost: gate must detect it.
    try expect(recovered.generation() != liar.generation());
}

test "negative control detects a published root preceding payload durability even when fallback works" {
    var base = Device{};
    try baseline(&base);
    var complete = base;
    var store = try Store.recover(&complete);
    try update(&store);
    // Deliberately publish only the valid gen-3 root before its new payload.
    // Recovery can fall back, but that must not hide the ordering violation.
    @memcpy(base.stable[model.page_bytes .. 2 * model.page_bytes], complete.stable[model.page_bytes .. 2 * model.page_bytes]);
    base.powerLoss();
    var recovered = try Store.recover(&base);
    try state(&recovered, 2);
    try expect(!publishedRootsComplete(&base, &recovered));
}

test "metadata-only truncate delete and empty creation recover atomically at every barrier" {
    var base = Device{};
    try baseline(&base);
    var cuts: usize = 0;
    for ([_]media.Background{ .none, .alternating, .all }) |background| {
        for ([_]media.Order{ .ascending, .descending }) |order| {
            var clean = base;
            clean.background = background;
            clean.order = order;
            var normal = try Store.recover(&clean);
            try metadataUpdate(&normal);
            try equal(@as(usize, 18), clean.events);
            clean.powerLoss();
            var acknowledged = try Store.recover(&clean);
            try metadataState(&acknowledged);
            try equal(@as(u64, 3), acknowledged.generation());
            for (0..18) |event| {
                for ([_]usize{ 0, 1, 31, 255, 511, 512 }) |prefix| {
                    var broken = base;
                    broken.background = background;
                    broken.order = order;
                    broken.cut = .{ .event = event, .prefix = prefix };
                    var interrupted = try Store.recover(&broken);
                    try expectError(error.Io, metadataUpdate(&interrupted));
                    broken.powerLoss();
                    var recovered = try Store.recover(&broken);
                    try metadataState(&recovered);
                    try expect(publishedRootsComplete(&broken, &recovered));
                    cuts += 1;
                }
            }
        }
    }
    try equal(@as(usize, 648), cuts);
    std.debug.print("STORE_MODEL_METADATA events=18 crash_cases={d} acknowledged_cases=6\n", .{cuts});
}

fn metadataUpdate(store: *Store) !void {
    try store.begin();
    try store.truncate(1, 513);
    try store.remove(2);
    try store.put(3, "");
    try store.commit();
}

fn metadataState(store: *Store) !void {
    if (store.generation() == 2) return state(store, 2);
    try equal(@as(u64, 3), store.generation());
    try object(store, 1, old_a[0..513]);
    try object(store, 3, "");
    var byte: [1]u8 = undefined;
    try expectError(error.NotFound, store.read(2, 0, &byte));
}

test "interrupted initial publication never silently mounts a torn root" {
    var cuts: usize = 0;
    for ([_]media.Background{ .none, .alternating, .all }) |background| {
        for ([_]media.Order{ .ascending, .descending }) |order| {
            var clean = Device{ .background = background, .order = order };
            _ = try Store.format(&clean);
            try equal(@as(usize, 17), clean.events);
            clean.powerLoss();
            const acknowledged = try Store.recover(&clean);
            try equal(@as(u64, 1), acknowledged.generation());
            for (0..17) |event| {
                for ([_]usize{ 0, 1, 31, 255, 511, 512 }) |prefix| {
                    var broken = Device{ .background = background, .order = order, .cut = .{ .event = event, .prefix = prefix } };
                    try expectError(error.Io, Store.format(&broken));
                    broken.powerLoss();
                    cuts += 1;
                    const recovered = Store.recover(&broken) catch |err| switch (err) {
                        error.Unformatted, error.Corrupt => continue,
                        else => return err,
                    };
                    try equal(@as(u64, 1), recovered.generation());
                }
            }
        }
    }
    try equal(@as(usize, 612), cuts);
    std.debug.print("STORE_MODEL_INITIAL events=17 crash_cases={d} acknowledged_cases=6\n", .{cuts});
}

test "alternating roots survive repeated publication and abandoned payload space is reusable" {
    var device = Device{};
    try baseline(&device);
    var store = try Store.recover(&device);
    try store.begin();
    try store.put(1, &new_a);
    try store.rollback(); // Leave dirty, unreachable payload behind.
    try store.begin();
    try store.put(3, &new_c); // Reuse the unpublished range, not live bytes.
    try store.commit();
    device.powerLoss();
    store = try Store.recover(&device);
    try object(&store, 1, &old_a);
    try object(&store, 2, &old_b);
    try object(&store, 3, &new_c);
    for (4..14) |generation| {
        try store.begin();
        try store.truncate(1, @intCast(600 - generation));
        try store.commit();
        device.powerLoss();
        store = try Store.recover(&device);
        try equal(@as(u64, @intCast(generation)), store.generation());
        try object(&store, 1, old_a[0 .. 600 - generation]);
        try object(&store, 2, &old_b);
        try object(&store, 3, &new_c);
    }
}

test "rollback truncate and empty objects keep metadata changes transactional" {
    var device = Device{};
    try baseline(&device);
    var store = try Store.recover(&device);
    try store.begin();
    try store.put(1, &new_a);
    try store.rollback();
    device.powerLoss();
    store = try Store.recover(&device);
    try state(&store, 2);
    try store.begin();
    try store.truncate(1, 513);
    try store.truncate(2, 0);
    try store.put(3, "");
    try expectError(error.InvalidArgument, store.truncate(1, 514));
    try store.commit();
    device.powerLoss();
    var recovered = try Store.recover(&device);
    try object(&recovered, 1, old_a[0..513]);
    try object(&recovered, 2, "");
    try object(&recovered, 3, "");
}

test "space and object admission fail before writes and larger objects have no 64 KiB transaction ceiling" {
    var small = media.Media(4 * model.page_bytes){};
    const Small = model.Store(@TypeOf(small), 1);
    var store = try Small.format(&small);
    try store.begin();
    const events = small.events;
    try expectError(error.NoSpace, store.put(1, &old_a ++ old_b));
    try equal(events, small.events);
    try store.put(1, "");
    const after = small.events;
    try expectError(error.TooManyObjects, store.put(2, ""));
    try equal(after, small.events);
    try store.commit();
    var large = media.Media(24 * model.page_bytes){};
    const Large = model.Store(@TypeOf(large), 2);
    var blob = try Large.format(&large);
    try blob.begin();
    const data = pattern(70 * 1024 + 1, 0x75);
    try blob.put(9, &data);
    try blob.commit();
    large.powerLoss();
    var recovered = try Large.recover(&large);
    try object(&recovered, 9, &data);
}

fn rootChecksum(device: *Device, slot: usize) void {
    const page = device.cache[slot * model.page_bytes ..][0..model.page_bytes];
    std.mem.writeInt(u32, page[model.checksum_offset..][0..4], std.hash.Crc32.hash(page[0..model.checksum_offset]), .little);
    device.stable = device.cache;
}

test "recovery validates bounds identities versions checksums and payload before trusting a root" {
    var base = Device{};
    try baseline(&base);
    // Corrupt the newest root while retaining a valid checksum. Gen 1 is
    // still available in slot 1, so malformed gen 2 must never be selected.
    for ([_][2]u32{ .{ 0, 0 }, .{ 4, 999 }, .{ 16, 0xffffffff }, .{ 20, 9 }, .{ 24, 0 }, .{ 28, 0 }, .{ 28, 0xffffffff }, .{ 32, 0xffffffff }, .{ 40, 1 }, .{ 44, 2 } }) |change| {
        var broken = base;
        std.mem.writeInt(u32, broken.cache[change[0]..][0..4], change[1], .little);
        rootChecksum(&broken, 0);
        var recovered = try Store.recover(&broken);
        try equal(@as(u64, 1), recovered.generation());
        var byte: [1]u8 = undefined;
        try expectError(error.NotFound, recovered.read(1, 0, &byte));
    }
    var torn = base;
    torn.cache[model.page_bytes * 2 + 17] ^= 1;
    torn.stable = torn.cache;
    const fallback = try Store.recover(&torn);
    try equal(@as(u64, 1), fallback.generation());
    torn.cache[model.page_bytes + 1] ^= 1;
    torn.stable = torn.cache;
    try expectError(error.Corrupt, Store.recover(&torn));
}

test "blank corrupt media and backend read errors are not silently formatted or reused" {
    var device = Device{};
    try expectError(error.Unformatted, Store.recover(&device));
    try equal(@as(usize, 0), device.events);
    try baseline(&device);
    try expectError(error.Corrupt, Store.format(&device));
    var store = try Store.recover(&device);
    device.read_error = true;
    try store.begin();
    try expectError(error.Io, store.truncate(1, 13));
    try expectError(error.Faulted, store.commit());
    try expectError(error.Io, Store.recover(&device));
}

test "generation exhaustion cannot wrap or write a new transaction" {
    var device = Device{};
    _ = try Store.format(&device);
    std.mem.writeInt(u64, device.cache[model.page_bytes + 8 ..][0..8], std.math.maxInt(u64), .little);
    rootChecksum(&device, 1);
    var recovered = try Store.recover(&device);
    try expectError(error.GenerationExhausted, recovered.begin());
}
