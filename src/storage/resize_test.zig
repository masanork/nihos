const std = @import("std");
const model = @import("checkpoint_model.zig");
const map = @import("extent_map.zig");
const media = @import("model_media.zig");
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const page = model.page_bytes;
const Backend = media.Media(64 * page);
const Store = model.Store(Backend, .{ .leaf_pages = 1, .index_pages = 8, .leaf_cache_pages = 1 });
const payload: [5003]u8 = @splat(0xa7);
fn seed(store: *Store, backend: *Backend) !void {
    try store.format(backend);
    try store.begin();
    try store.put(1, &payload);
    try store.commit();
    try store.begin();
    try store.promoteMapped(1);
    try store.commit();
}
fn check(store: *Store, length: u64, zero_after: u64) !void {
    try equal(length, (try store.get(1)).length);
    var bytes: [page]u8 = undefined;
    var offset: u64 = 0;
    while (offset < length) {
        const n = try store.read(1, offset, &bytes);
        try expect(n != 0);
        for (bytes[0..n], 0..) |byte, i| try equal(@as(u8, if (offset + i < zero_after) 0xa7 else 0), byte);
        offset += n;
    }
    try store.verify(1);
}
fn resize(store: *Store, length: u64) !void {
    var scratch = model.ResizeScratch{};
    try store.begin();
    const pages = try store.mappedResizePages(1, length, &scratch);
    try store.beginPayloadSearch(pages);
    while (true) switch (try store.stepPayloadSearch(.{ .leaf_visits = 1, .bitmap_pages = 1 })) {
        .pending => {},
        .found => break,
        else => return error.BadSearch,
    };
    try store.resizeMappedPrepared(1, length, &scratch);
    try store.commit();
}
test "truncate and regrow cannot resurrect bytes while old readers retain them" {
    var backend = Backend{};
    var store = Store{};
    try seed(&store, &backend);
    const reader = try store.pin();
    try resize(&store, 4099);
    try check(&store, 4099, 4099);
    try resize(&store, payload.len);
    try check(&store, payload.len, 4099);
    var old: [payload.len]u8 = undefined;
    try equal(payload.len, try store.readPinned(reader, 1, 0, &old));
    try std.testing.expectEqualSlices(u8, &payload, &old);
    try store.collectPayload();
    try store.release(reader);
    try store.collectPayload();
    backend.powerLoss();
    var reopened = Store{};
    try reopened.recover(&backend);
    try check(&reopened, payload.len, 4099);
}
test "sparse growth allocates no zero data and patches materialize only one path" {
    const WideDevice = struct {
        pub const capacity: u64 = 16 * 1024 * 1024 * 1024;
        backend: *Backend,
        pub fn read(self: *@This(), offset: u64, bytes: []u8) error{Io}!void {
            return self.backend.read(offset, bytes);
        }
        pub fn write(self: *@This(), offset: u64, bytes: []const u8) error{Io}!void {
            return self.backend.write(offset, bytes);
        }
        pub fn sync(self: *@This()) error{Io}!void {
            return self.backend.sync();
        }
    };
    const Wide = model.Store(WideDevice, .{ .leaf_pages = 1, .index_pages = 8 });
    var backend = Backend{};
    var device = WideDevice{ .backend = &backend };
    var store = Wide{};
    var scratch = model.ResizeScratch{};
    try store.format(&device);
    try store.begin();
    try store.put(1, "");
    try store.commit();
    try store.begin();
    try equal(@as(u64, 1), try store.mappedResizePages(1, WideDevice.capacity, &scratch));
    try store.resizeMapped(1, WideDevice.capacity, &scratch);
    try store.commit();
    var bytes: [17]u8 = @splat(0xff);
    try equal(bytes.len, try store.read(1, WideDevice.capacity - bytes.len, &bytes));
    try std.testing.expectEqualSlices(u8, &@as([17]u8, @splat(0)), &bytes);
    try store.begin();
    try store.patchMappedPage(1, WideDevice.capacity - 2, "OK");
    try store.commit();
    try equal(bytes.len, try store.read(1, WideDevice.capacity - bytes.len, &bytes));
    try std.testing.expectEqualSlices(u8, "OK", bytes[15..]);
    try store.begin();
    try store.resizeMapped(1, page, &scratch);
    try store.commit();
    try store.begin();
    try store.resizeMapped(1, WideDevice.capacity, &scratch);
    try store.commit();
    _ = try store.read(1, WideDevice.capacity - bytes.len, &bytes);
    try std.testing.expectEqualSlices(u8, &@as([17]u8, @splat(0)), &bytes);
}
test "growth wraps and shrink collapses map height while preserving shared prefix" {
    // Logical size fits the backend, but exceeds a leaf's 252 logical pages.
    const BigBackend = media.Media(300 * page);
    const Big = model.Store(BigBackend, .{ .leaf_pages = 1, .index_pages = 8 });
    const backend = try std.testing.allocator.create(BigBackend);
    defer std.testing.allocator.destroy(backend);
    backend.* = .{};
    var store = Big{};
    var scratch = model.ResizeScratch{};
    try store.format(backend);
    try store.begin();
    try store.put(1, &payload);
    try store.commit();
    try store.begin();
    try store.promoteMapped(1);
    try store.commit();
    try store.begin();
    try store.resizeMapped(1, 253 * page, &scratch);
    try store.commit();
    var bytes: [4]u8 = undefined;
    _ = try store.read(1, 252 * page, &bytes);
    try std.testing.expectEqualSlices(u8, &@as([4]u8, @splat(0)), &bytes);
    try store.begin();
    try store.patchMappedPage(1, 252 * page, "tail");
    try store.commit();
    try store.begin();
    try equal(@as(u64, 0), try store.mappedResizePages(1, 252 * page, &scratch));
    try store.resizeMapped(1, 252 * page, &scratch);
    try store.commit();
    try store.begin();
    try store.resizeMapped(1, 2 * page, &scratch);
    try store.commit();
    _ = try store.read(1, payload.len - 2, bytes[0..2]);
    try equal(@as(u8, 0xa7), bytes[0]);
    try store.begin();
    try store.resizeMapped(1, 253 * page, &scratch);
    try store.commit();
    try store.collectPayload();
    _ = try store.read(1, 252 * page, &bytes);
    try std.testing.expectEqualSlices(u8, &@as([4]u8, @splat(0)), &bytes);
    try store.verify(1);
}
test "resize rejects unavailable search and active streams without changing committed data" {
    var backend = Backend{};
    var store = Store{};
    var scratch = model.ResizeScratch{};
    try seed(&store, &backend);
    try store.begin();
    try expectError(error.SearchRequired, store.resizeMappedPrepared(1, 4099, &scratch));
    try expectError(error.NotFound, store.resizeMapped(2, 10, &scratch));
    try expectError(error.InvalidArgument, store.resizeMapped(1, Backend.capacity + 1, &scratch));
    const stream = try store.beginStream(2, 1);
    try expectError(error.Busy, store.resizeMapped(1, 0, &scratch));
    try store.abortStream(stream);
    try store.resizeMapped(1, 4099, &scratch);
    try store.rollback();
    try check(&store, payload.len, payload.len);
    try resize(&store, 0);
    try resize(&store, payload.len);
    try check(&store, payload.len, 0);
}
test "mixed EOF boundaries sparse patches and collection match a byte oracle" {
    const BigBackend = media.Media(300 * page);
    const Big = model.Store(BigBackend, .{ .leaf_pages = 1, .index_pages = 8 });
    const backend = try std.testing.allocator.create(BigBackend);
    defer std.testing.allocator.destroy(backend);
    backend.* = .{};
    const oracle = try std.testing.allocator.alloc(u8, 253 * page);
    defer std.testing.allocator.free(oracle);
    @memset(oracle, 0);
    var store = Big{};
    var scratch = model.ResizeScratch{};
    try store.format(backend);
    try store.begin();
    try store.put(1, "");
    try store.commit();
    const sizes = [_]usize{ 4097, 253 * page, 252 * page, 5003, 0, 252 * page + 1, 4095, page, 1 };
    var old_length: usize = 0;
    for (0..36) |step| {
        const size = sizes[(step * 7) % sizes.len];
        if (size > old_length) @memset(oracle[old_length..size], 0);
        try store.begin();
        try store.resizeMapped(1, size, &scratch);
        if (size != 0) {
            const offset = (step * 7919 + size - 1) % size;
            const change: [1]u8 = .{@truncate(step + 1)};
            try store.patchMappedPage(1, offset, &change);
            oracle[offset] = change[0];
        }
        try store.commit();
        try store.collectPayload();
        store.dropMetadataCache();
        var bytes: [page]u8 = undefined;
        var offset: usize = 0;
        while (offset < size) {
            const n = try store.read(1, offset, &bytes);
            try expect(n != 0);
            try std.testing.expectEqualSlices(u8, oracle[offset..][0..n], bytes[0..n]);
            offset += n;
        }
        try store.verify(1);
        old_length = size;
    }
}
test "insufficient payload space refuses resize before any write" {
    var backend = Backend{};
    var store = Store{};
    var scratch = model.ResizeScratch{};
    try seed(&store, &backend);
    const blocker: [49 * page]u8 = @splat(0x19);
    try store.begin();
    try store.put(2, &blocker);
    try store.commit();
    try equal(@as(u64, 1), (try store.payloadSpace()).free_pages);
    try store.begin();
    const before = backend.events;
    try equal(@as(u64, 2), try store.mappedResizePages(1, 4099, &scratch));
    try expectError(error.NoSpace, store.resizeMapped(1, 4099, &scratch));
    try equal(before, backend.events);
    try store.rollback();
    try check(&store, payload.len, payload.len);
}
test "version four roots are refused without writes or automatic migration" {
    var backend = Backend{};
    var store = Store{};
    try seed(&store, &backend);
    backend.powerLoss();
    for (0..2) |slot| {
        const root = backend.cache[slot * page ..][0..page];
        std.mem.writeInt(u32, root[4..8], 4, .little);
        std.mem.writeInt(u32, root[model.crc_offset..][0..4], std.hash.Crc32.hash(root[0..model.crc_offset]), .little);
    }
    backend.stable = backend.cache;
    backend.powerLoss();
    var reopened = Store{};
    try expectError(error.Corrupt, reopened.recover(&backend));
    try equal(@as(usize, 0), backend.events);
}
fn campaign(comptime length: u64) !void {
    var base = Backend{};
    var seeded = Store{};
    if (length == Backend.capacity) {
        try seeded.format(&base);
        try seeded.begin();
        try seeded.put(1, "");
        try seeded.commit();
    } else try seed(&seeded, &base);
    base.powerLoss();
    var cases: usize = 0;
    var events: usize = 0;
    for ([_]media.Background{ .none, .alternating, .all }) |background| {
        for ([_]media.Order{ .ascending, .descending }) |order| {
            var clean = base;
            clean.background = background;
            clean.order = order;
            var store = Store{};
            try store.recover(&clean);
            try resize(&store, length);
            events = clean.events;
            clean.powerLoss();
            var acknowledged = Store{};
            try acknowledged.recover(&clean);
            const old_generation: u64 = if (length == Backend.capacity) 2 else 3;
            try equal(old_generation + 1, acknowledged.generation());
            try check(&acknowledged, length, if (length == Backend.capacity) 0 else @min(length, payload.len));
            for (0..events) |event| for ([_]usize{ 0, 1, 31, 255, 511, 512 }) |prefix| {
                var broken = base;
                broken.background = background;
                broken.order = order;
                var interrupted = Store{};
                try interrupted.recover(&broken);
                broken.cut = .{ .event = event, .prefix = prefix };
                try expectError(error.Io, resize(&interrupted, length));
                broken.powerLoss();
                var recovered = Store{};
                try recovered.recover(&broken);
                const new = recovered.generation() == old_generation + 1;
                try expect(new or recovered.generation() == old_generation);
                const empty = length == Backend.capacity;
                try check(&recovered, if (new) length else if (empty) 0 else payload.len, if (empty) 0 else if (new) @min(length, payload.len) else payload.len);
                cases += 1;
            };
        }
    }
    try equal(@as(usize, if (length == 0) 34 else if (length == Backend.capacity) 50 else 66), events);
    try equal(@as(usize, if (length == 0) 1224 else if (length == Backend.capacity) 1800 else 2376), cases);
    std.debug.print("RESIZE_CAMPAIGN length={d} events={d} crash_cases={d} acknowledged_cases=6\n", .{ length, events, cases });
}
test "partial tail shrink publication survives every write and sync cut" {
    try campaign(4099);
}
test "partial tail growth publication survives every write and sync cut" {
    try campaign(9000);
}
test "zero truncate publication survives every write and sync cut" {
    try campaign(0);
}
test "sparse growth from empty survives every write and sync cut" {
    try campaign(Backend.capacity);
}
test "implicit zero references reject nonzero checksum and metadata summaries" {
    var bytes: [page]u8 = undefined;
    try map.init(&bytes, 0, 0, 1);
    map.setData(&bytes, 0, .{ .page = 0, .checksum = 1 });
    try expectError(error.Corrupt, map.seal(&bytes, 10, 0, 0, 1, .{ .start = 2, .end = 20 }));
    const length = (map.leaf_entries + 1) * page;
    try map.init(&bytes, 1, 0, length);
    map.setChild(&bytes, 0, .{ .nodes = .{ .low = 10, .high = 11 } });
    try expectError(error.Corrupt, map.seal(&bytes, 10, 1, 0, length, .{ .start = 2, .end = 20 }));
}
