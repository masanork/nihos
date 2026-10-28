const std = @import("std");
const model = @import("checkpoint_model.zig");
const map = @import("extent_map.zig");
const media = @import("model_media.zig");
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const page = model.page_bytes;
const Backend = media.Media(64 * page);
const Device = struct {
    pub const capacity = Backend.capacity;
    backend: *Backend,
    reads: usize = 0,
    writes: usize = 0,
    pub fn read(self: *@This(), offset: u64, destination: []u8) error{Io}!void {
        self.reads += destination.len;
        return self.backend.read(offset, destination);
    }
    pub fn write(self: *@This(), offset: u64, input: []const u8) error{Io}!void {
        self.writes += input.len;
        return self.backend.write(offset, input);
    }
    pub fn sync(self: *@This()) error{Io}!void {
        return self.backend.sync();
    }
};
const Store = model.Store(Device, .{ .leaf_pages = 1, .index_pages = 8, .leaf_cache_pages = 1, .payload_window_bytes = 1, .payload_reserve_pages = 2 });
const payload: [5003]u8 = result: {
    @setEvalBranchQuota(20000);
    var value: [5003]u8 = undefined;
    for (&value, 0..) |*byte, i| byte.* = @truncate(i *% 17 +% 0x31);
    break :result value;
};
fn initial(store: *Store, device: *Device) !void {
    try store.format(device);
    try store.begin();
    try store.put(1, &payload);
    try store.commit();
}
fn object(store: *Store, expected: []const u8) !void {
    var actual: [payload.len]u8 = undefined;
    try equal(expected.len, try store.read(1, 0, &actual));
    try std.testing.expectEqualSlices(u8, expected, actual[0..expected.len]);
    try store.verify(1);
}
fn readerObject(store: *Store, reader: model.Reader, expected: []const u8) !void {
    var actual: [payload.len]u8 = undefined;
    const n = store.readPinned(reader, 1, 0, &actual) catch |err| {
        std.debug.print("EXTENT_READER_COUNTEREXAMPLE error={s}\n", .{@errorName(err)});
        return err;
    };
    try equal(expected.len, n);
    try std.testing.expectEqualSlices(u8, expected, actual[0..expected.len]);
}

test "pinned mapped data and map nodes survive physical page reuse" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    try initial(&store, &device);
    try store.begin();
    try store.promoteMapped(1);
    try store.commit();
    try store.collectPayload();
    const reader = try store.pin();
    for (0..128) |i| {
        const change: [1]u8 = .{@truncate(i)};
        try store.begin();
        store.patchMappedPage(1, 1, &change) catch |err| {
            std.debug.print("EXTENT_UPDATE_COUNTEREXAMPLE error={s}\n", .{@errorName(err)});
            return err;
        };
        try store.commit();
        try store.collectPayload();
        try readerObject(&store, reader, &payload);
    }
    try store.release(reader);
}

test "promotion writes map metadata only and old readers retain their original file" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    try initial(&store, &device);
    const blob = try store.pin();
    try store.begin();
    const writes = device.writes;
    try store.promoteMapped(1);
    try equal(@as(usize, 2 * page), device.writes - writes);
    try store.commit();
    try equal(model.Kind.mapped, (try store.get(1)).kind);
    try object(&store, &payload);
    const mapped = try store.pin();
    try store.begin();
    try store.patchMappedPage(1, page - 3, "XYZ");
    try store.patchMappedPage(1, page, "123");
    try store.commit();
    var expected = payload;
    @memcpy(expected[page - 3 ..][0..6], "XYZ123");
    try object(&store, &expected);
    try readerObject(&store, blob, &payload);
    try readerObject(&store, mapped, &payload);
    try store.collectPayload();
    const before = (try store.payloadSpace()).free_pages;
    try store.release(blob);
    try equal(before + 1, (try store.payloadSpace()).free_pages); // Original checksum sidecar.
    try store.release(mapped);
    try equal(before + 4, (try store.payloadSpace()).free_pages); // Old two data pages and map leaf.
}

test "repeated mapped page changes reuse physical storage without losing shared pages" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    try initial(&store, &device);
    try store.begin();
    try store.promoteMapped(1);
    try store.commit();
    try store.collectPayload();
    var expected = payload;
    for (0..128) |i| {
        const change: [1]u8 = .{@truncate(i)};
        try store.begin();
        try store.patchMappedPage(1, 1, &change);
        try store.commit();
        try store.collectPayload();
        expected[1] = change[0];
        store.dropMetadataCache();
        try object(&store, &expected);
    }
    const space = try store.payloadSpace();
    try equal(space.usable_pages - 3, space.free_pages); // Two data pages plus one map leaf.
    std.debug.print("EXTENT_REUSE patches=128 live_payload_pages=3 unchanged_page_preserved=true\n", .{});
}

test "map search visits are budgeted and aborted mapped updates preserve the committed view" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    try initial(&store, &device);
    try store.begin();
    try store.promoteMapped(1);
    try store.commit();
    const reader = try store.pin();
    try store.beginPayloadSpace();
    var steps: usize = 0;
    while (true) {
        const before = device.reads;
        const result = try store.stepPayloadSearch(.{ .leaf_visits = 1, .bitmap_pages = 1 });
        try expect(device.reads - before <= page);
        try expect(store.step_leaf_visits <= 1 and store.step_bitmap_pages <= 1);
        steps += 1;
        // The mapped reader clobbers map_buffer between traversal steps.
        try readerObject(&store, reader, &payload);
        switch (result) {
            .pending => {},
            .space => break,
            else => return error.BadSearch,
        }
    }
    try expect(steps > 1);
    try store.begin();
    try expectError(error.SearchRequired, store.patchMappedPagePrepared(1, 0, "x"));
    try store.beginPayloadSearch(try Store.mappedPatchPages(payload.len));
    while (true) switch (try store.stepPayloadSearch(.{})) {
        .pending => {},
        .found => break,
        else => return error.BadSearch,
    };
    try store.patchMappedPagePrepared(1, 0, "x");
    try store.rollback();
    try object(&store, &payload);
    try store.release(reader);
}

test "map checksums cached metadata and data CRC reject corruption before copying" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    try initial(&store, &device);
    try store.begin();
    try store.promoteMapped(1);
    try store.commit();
    const value = try store.get(1);
    var byte: [1]u8 = @splat(0xee);
    _ = try store.read(1, 0, &byte); // Warm the map leaf cache.
    store.map_buffer[map.header_bytes] ^= 1;
    byte[0] = 0xee;
    try expectError(error.Corrupt, store.read(1, 0, &byte));
    try equal(@as(u8, 0xee), byte[0]);
    backend.powerLoss();
    var reopened = Store{};
    try reopened.recover(&device);
    backend.cache[value.first * page + 17] ^= 1;
    try expectError(error.Corrupt, reopened.read(1, 0, &byte));
    try expectError(error.Faulted, reopened.begin());
}

fn setup(backend: *Backend) !void {
    var device = Device{ .backend = backend };
    var store = Store{};
    try initial(&store, &device);
    try store.begin();
    try store.promoteMapped(1);
    try store.commit();
    backend.powerLoss();
}
fn update(store: *Store, ack: *u64) !void {
    try store.collectPayload();
    ack.* = store.generation();
    try store.begin();
    try store.patchMappedPage(1, 1, "XYZ");
    try store.commit();
    ack.* = store.generation();
}
fn campaign(comptime promotion: bool) !void {
    var base = Backend{};
    if (promotion) {
        var device = Device{ .backend = &base };
        var store = Store{};
        try initial(&store, &device);
        base.powerLoss();
    } else try setup(&base);
    var cases: usize = 0;
    var changed = payload;
    @memcpy(changed[1..4], "XYZ");
    for ([_]media.Background{ .none, .alternating, .all }) |background| {
        for ([_]media.Order{ .ascending, .descending }) |order| {
            var clean = base;
            clean.background = background;
            clean.order = order;
            var device = Device{ .backend = &clean };
            var store = Store{};
            try store.recover(&device);
            var ack: u64 = if (promotion) 2 else 3;
            if (promotion) {
                try store.begin();
                try store.promoteMapped(1);
                try store.commit();
                ack = store.generation();
            } else try update(&store, &ack);
            try equal(@as(u64, if (promotion) 3 else 5), ack);
            const events = clean.events;
            try equal(@as(usize, if (promotion) 50 else 84), events);
            clean.powerLoss();
            var acknowledged = Store{};
            try acknowledged.recover(&device);
            try equal(@as(u64, if (promotion) 3 else 5), acknowledged.generation());
            try object(&acknowledged, if (promotion) &payload else &changed);
            for (0..events) |event| {
                for ([_]usize{ 0, 1, 31, 255, 511, 512 }) |prefix| {
                    var broken = base;
                    broken.background = background;
                    broken.order = order;
                    var failing = Device{ .backend = &broken };
                    var interrupted = Store{};
                    try interrupted.recover(&failing);
                    broken.cut = .{ .event = event, .prefix = prefix };
                    var last_ack: u64 = if (promotion) 2 else 3;
                    if (promotion) {
                        try interrupted.begin();
                        try expectError(error.Io, promoteAndCommit(&interrupted));
                    } else try expectError(error.Io, update(&interrupted, &last_ack));
                    broken.powerLoss();
                    var recovered = Store{};
                    try recovered.recover(&failing);
                    try expect(recovered.generation() >= last_ack and recovered.generation() <= (if (promotion) @as(u64, 3) else 5));
                    try object(&recovered, if (!promotion and recovered.generation() == 5) &changed else &payload);
                    cases += 1;
                }
            }
        }
    }
    try equal(@as(usize, if (promotion) 1800 else 3024), cases);
    std.debug.print("{s}_CAMPAIGN events={d} crash_cases={d} acknowledged_cases=6\n", .{ if (promotion) "PROMOTION" else "EXTENT", if (promotion) @as(usize, 50) else 84, cases });
}
fn promoteAndCommit(store: *Store) !void {
    try store.promoteMapped(1);
    try store.commit();
}
test "shared extent publication survives every write sync and reuse cut" {
    try campaign(false);
}
test "map promotion survives every metadata publication cut without copying payload" {
    try campaign(true);
}

test "map geometry uses bounded depth for sixteen GiB and validates physical summaries" {
    try equal(@as(u8, 3), try map.height(16 * 1024 * 1024 * 1024));
    try equal(@as(u64, 35), try Store.mapMetadataPages(33 * 1024 * 1024 + 17));
    var buffer: [page]u8 = undefined;
    try map.init(&buffer, 0, 0, 4097);
    map.setData(&buffer, 0, .{ .page = 10, .checksum = 123 });
    map.setData(&buffer, 1, .{ .page = 100, .checksum = 456 });
    const ref = try map.seal(&buffer, 120, 0, 0, 4097, .{ .start = 2, .end = 200 });
    try equal(@as(u32, 10), ref.data.low);
    try equal(@as(u32, 101), ref.data.high);
    try equal(@as(u32, 120), ref.nodes.low);
    try equal(@as(u32, 121), ref.nodes.high);
    _ = try map.validate(&buffer, ref, 0, 0, 4097, .{ .start = 2, .end = 200 });
    std.mem.writeInt(u32, buffer[36..40], 100, .little);
    var forged = ref;
    forged.checksum = std.hash.Crc32.hash(buffer[0..map.crc_offset]);
    std.mem.writeInt(u32, buffer[map.crc_offset..][0..4], forged.checksum, .little);
    try expectError(error.Corrupt, map.validate(&buffer, forged, 0, 0, 4097, .{ .start = 2, .end = 200 }));
}

test "internal node summaries protect metadata far from its shared data" {
    const file_media = @import("file_media.zig");
    const File = file_media.Media(512 * page);
    const Mapped = model.Store(File, .{ .leaf_pages = 1, .index_pages = 8, .payload_window_bytes = 1, .leaf_cache_pages = 1 });
    const length = map.leaf_entries * page + 17;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.testing.io;
    {
        const file = try dir.dir.createFile(io, "mapped", .{ .read = true, .exclusive = true });
        defer file.close(io);
        try file.setLength(io, File.capacity);
        const blank: [2 * page]u8 = @splat(0xff);
        try file.writePositionalAll(io, &blank, 0);
        try file.sync(io);
    }
    var device = try File.open(io, dir.dir, "mapped");
    defer device.close();
    var store = Mapped{};
    try store.format(&device);
    try store.begin();
    var buffer: [page]u8 = @splat(0x31);
    for ([_]u64{ length, 32 * page }, 1..) |size, key| {
        const stream = try store.beginStream(@intCast(key), size);
        var written: u64 = 0;
        while (written < size) written += try store.writeStream(stream, buffer[0..@intCast(@min(buffer.len, size - written))]);
        try store.finishStream(stream);
    }
    try store.commit();
    try store.begin();
    try store.remove(2);
    try store.commit();
    try store.collectPayload();
    try store.begin();
    try store.promoteMapped(1);
    try store.commit();
    try store.collectPayload();
    const space = try store.payloadSpace();
    try equal(@as(u64, 502 - 253 - 3), space.free_pages);
    try store.verify(1);
    try store.begin();
    try store.patchMappedPage(1, map.leaf_entries * page - 1, "X");
    try store.patchMappedPage(1, map.leaf_entries * page, "Y");
    try store.commit();
    var crossing: [2]u8 = undefined;
    try equal(crossing.len, try store.read(1, map.leaf_entries * page - 1, &crossing));
    try std.testing.expectEqualSlices(u8, "XY", &crossing);
    try store.verify(1);
}

test "version three roots are rejected without migration or writes" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    try initial(&store, &device);
    backend.powerLoss();
    for (0..2) |slot| {
        const root = backend.cache[slot * page ..][0..page];
        std.mem.writeInt(u32, root[4..8], 3, .little);
        std.mem.writeInt(u32, root[model.crc_offset..][0..4], std.hash.Crc32.hash(root[0..model.crc_offset]), .little);
    }
    backend.stable = backend.cache;
    backend.powerLoss();
    const before = device.writes;
    var wrong = Store{};
    try expectError(error.Corrupt, wrong.recover(&device));
    try equal(before, device.writes);
}
