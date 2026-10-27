const std = @import("std");
const model = @import("checkpoint_model.zig");
const media = @import("model_media.zig");
const map = @import("extent_map.zig");
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const page = model.page_bytes;
const Backend = media.Media(64 * page);
const Device = struct {
    pub const capacity: u64 = 16 * 1024 * 1024 * 1024;
    backend: *Backend,
    writes: usize = 0,
    pub fn read(self: *@This(), offset: u64, bytes: []u8) error{Io}!void {
        return self.backend.read(offset, bytes);
    }
    pub fn write(self: *@This(), offset: u64, bytes: []const u8) error{Io}!void {
        self.writes += bytes.len;
        return self.backend.write(offset, bytes);
    }
    pub fn sync(self: *@This()) error{Io}!void {
        return self.backend.sync();
    }
};
// Bounded physical test window; large logical holes never reach the backend.
const Store = model.Store(Device, .{ .leaf_pages = 1, .index_pages = 8, .leaf_cache_pages = 1, .payload_reserve_pages = Device.capacity / page - 64 });
const payload: [5003]u8 = @splat(0xa7);
const sparse_length = 253 * page;
fn seed(store: *Store, device: *Device, comptime sparse: bool) !void {
    var scratch = model.MapScratch{};
    try store.format(device);
    try store.begin();
    try store.put(1, if (sparse) "" else &payload);
    try store.commit();
    try store.begin();
    if (sparse) try store.resizeMapped(1, sparse_length, &scratch) else try store.promoteMapped(1);
    try store.commit();
}
fn patchesFor(comptime sparse: bool) [2]model.MappedPatch {
    return .{ .{ .offset = 1, .bytes = "X" }, .{ .offset = (if (sparse) 252 * page else page) + 3, .bytes = "Y" } };
}
fn check(store: *Store, comptime sparse: bool, changed: bool) !void {
    const patches = patchesFor(sparse);
    try equal(@as(u64, if (sparse) sparse_length else payload.len), (try store.get(1)).length);
    if (sparse) {
        var byte: [1]u8 = undefined;
        for (patches, 0..) |patch, i| {
            try equal(@as(usize, 1), try store.read(1, patch.offset, &byte));
            try equal(@as(u8, if (changed) (if (i == 0) 'X' else 'Y') else 0), byte[0]);
        }
        _ = try store.read(1, 200 * page + 9, &byte);
        try equal(@as(u8, 0), byte[0]);
    } else {
        var expected = payload;
        if (changed) for (patches) |patch| {
            expected[@intCast(patch.offset)] = patch.bytes[0];
        };
        var actual: [payload.len]u8 = undefined;
        try equal(payload.len, try store.read(1, 0, &actual));
        try std.testing.expectEqualSlices(u8, &expected, &actual);
    }
}
test "batch writes one shared map path and one object leaf while preserving old readers" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    var scratch = model.MapScratch{};
    try seed(&store, &device, false);
    const reader = try store.pin();
    const patches = patchesFor(false);
    try equal(@as(u64, 3), try Store.mappedBatchPages(payload.len, &patches));
    try store.begin();
    const before = device.writes;
    try store.patchMappedBatch(1, &patches, &scratch);
    try equal(@as(usize, 4 * page), device.writes - before);
    try check(&store, false, false);
    try store.commit();
    try equal(@as(usize, 5 * page), device.writes - before);
    try check(&store, false, true);
    var old: [payload.len]u8 = undefined;
    _ = try store.readPinned(reader, 1, 0, &old);
    try std.testing.expectEqualSlices(u8, &payload, &old);
    try store.release(reader);
}
test "batch admission validates every patch before writing and binds exact prepared allocation" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    var scratch = model.MapScratch{};
    try seed(&store, &device, false);
    try store.begin();
    const patches = patchesFor(false);
    const before = device.writes;
    try expectError(error.SearchRequired, store.patchMappedBatchPrepared(1, &patches, &scratch));
    const invalid = [_][2]model.MappedPatch{
        .{ patches[1], patches[0] },
        .{ patches[0], patches[0] },
        .{ patches[0], .{ .offset = payload.len, .bytes = "x" } },
        .{ patches[0], .{ .offset = page - 1, .bytes = "xy" } },
        .{ patches[0], .{ .offset = page, .bytes = "" } },
    };
    for (invalid) |bad| try expectError(error.InvalidArgument, store.patchMappedBatch(1, &bad, &scratch));
    try expectError(error.InvalidArgument, Store.mappedBatchPages(payload.len, &.{}));
    const too_many: [17]model.MappedPatch = @splat(patches[0]);
    try expectError(error.InvalidArgument, Store.mappedBatchPages(payload.len, &too_many));
    try equal(before, device.writes);
    try store.beginPayloadSearch(try Store.mappedBatchPages(payload.len, &patches));
    while (true) switch (try store.stepPayloadSearch(.{})) {
        .pending => {},
        .found => break,
        else => return error.BadSearch,
    };
    try store.patchMappedBatchPrepared(1, &patches, &scratch);
    try store.rollback();
    try check(&store, false, false);
    try store.begin();
    const stream = try store.beginStream(2, 1);
    try expectError(error.Busy, store.patchMappedBatch(1, &patches, &scratch));
    try store.abortStream(stream);
    try store.rollback();
}
test "batch spans all four map levels and GC preserves sparse siblings and old snapshots" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    var scratch = model.MapScratch{};
    try seed(&store, &device, true);
    try store.begin();
    try store.resizeMapped(1, Device.capacity, &scratch);
    try store.commit();
    const reader = try store.pin();
    const patches = [_]model.MappedPatch{
        .{ .offset = 0, .bytes = "A" },
        .{ .offset = (map.leaf_entries - 1) * page + 1, .bytes = "B" },
        .{ .offset = map.leaf_entries * page + 2, .bytes = "C" },
        .{ .offset = map.capacity(1) * page + 3, .bytes = "D" },
        .{ .offset = Device.capacity - 1, .bytes = "E" },
    };
    try store.begin();
    const wanted = try Store.mappedBatchPages(Device.capacity, &patches);
    try expect(wanted < patches.len * try Store.mappedPatchPages(Device.capacity));
    try store.patchMappedBatch(1, &patches, &scratch);
    try store.commit();
    try store.collectPayload();
    store.dropMetadataCache();
    for (patches) |patch| {
        var bytes: [1]u8 = undefined;
        _ = try store.read(1, patch.offset, &bytes);
        try std.testing.expectEqualSlices(u8, patch.bytes, &bytes);
        _ = try store.readPinned(reader, 1, patch.offset, &bytes);
        try equal(@as(u8, 0), bytes[0]);
    }
    try store.release(reader);
    try store.collectPayload();
    backend.powerLoss();
    var recovered = Store{};
    try recovered.recover(&device);
    for (patches) |patch| {
        var bytes: [1]u8 = undefined;
        _ = try recovered.read(1, patch.offset, &bytes);
        try std.testing.expectEqualSlices(u8, patch.bytes, &bytes);
    }
}
test "batch NoSpace is detected before writes and leaves the transaction usable" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    var scratch = model.MapScratch{};
    try seed(&store, &device, false);
    const blocker: [49 * page]u8 = @splat(0x19);
    try store.begin();
    try store.put(2, &blocker);
    try store.commit();
    try equal(@as(u64, 1), (try store.payloadSpace()).free_pages);
    try store.begin();
    const patches = patchesFor(false);
    const before = device.writes;
    try expectError(error.NoSpace, store.patchMappedBatch(1, &patches, &scratch));
    try equal(before, device.writes);
    try store.remove(2);
    try store.rollback();
    try check(&store, false, false);
}
test "sixteen page batches repeatedly reuse physical pages without corrupting pinned zero data" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    var scratch = model.MapScratch{};
    try seed(&store, &device, true);
    try store.begin();
    try store.resizeMapped(1, 16 * page, &scratch);
    try store.commit();
    try store.collectPayload();
    const reader = try store.pin();
    var changes: [16]u8 = undefined;
    var patches: [16]model.MappedPatch = undefined;
    for (&patches, 0..) |*patch, i| patch.* = .{ .offset = i * page, .bytes = changes[i..][0..1] };
    for (0..64) |step| {
        for (&changes, 0..) |*byte, i| byte.* = @truncate(step + i + 1);
        try store.begin();
        try store.patchMappedBatch(1, &patches, &scratch);
        try store.commit();
        try store.collectPayload();
        store.dropMetadataCache();
        for (patches, 0..) |patch, i| {
            var bytes: [2]u8 = undefined;
            _ = try store.read(1, patch.offset, &bytes);
            try equal(changes[i], bytes[0]);
            try equal(@as(u8, 0), bytes[1]);
            _ = try store.readPinned(reader, 1, patch.offset, &bytes);
            try equal(@as(u8, 0), bytes[0]);
        }
    }
    try store.release(reader);
}
fn update(store: *Store, comptime sparse: bool) !void {
    var scratch = model.MapScratch{};
    const patches = patchesFor(sparse);
    try store.begin();
    try store.patchMappedBatch(1, &patches, &scratch);
    try store.commit();
}
fn campaign(comptime sparse: bool) !void {
    var base = Backend{};
    var initial_device = Device{ .backend = &base };
    var seeded = Store{};
    try seed(&seeded, &initial_device, sparse);
    base.powerLoss();
    var cases: usize = 0;
    var events: usize = 0;
    for ([_]media.Background{ .none, .alternating, .all }) |background| {
        for ([_]media.Order{ .ascending, .descending }) |order| {
            var clean = base;
            clean.background = background;
            clean.order = order;
            var device = Device{ .backend = &clean };
            var store = Store{};
            try store.recover(&device);
            try update(&store, sparse);
            events = clean.events;
            clean.powerLoss();
            var acknowledged = Store{};
            try acknowledged.recover(&device);
            try equal(@as(u64, 4), acknowledged.generation());
            try check(&acknowledged, sparse, true);
            for (0..events) |event| for ([_]usize{ 0, 1, 31, 255, 511, 512 }) |prefix| {
                var broken = base;
                broken.background = background;
                broken.order = order;
                var failing = Device{ .backend = &broken };
                var interrupted = Store{};
                try interrupted.recover(&failing);
                broken.cut = .{ .event = event, .prefix = prefix };
                try expectError(error.Io, update(&interrupted, sparse));
                broken.powerLoss();
                var recovered = Store{};
                try recovered.recover(&failing);
                try expect(recovered.generation() == 3 or recovered.generation() == 4);
                try check(&recovered, sparse, recovered.generation() == 4);
                cases += 1;
            };
        }
    }
    try equal(@as(usize, if (sparse) 114 else 82), events);
    try equal(@as(usize, if (sparse) 4104 else 2952), cases);
    std.debug.print("BATCH_CAMPAIGN sparse={} events={d} crash_cases={d} acknowledged_cases=6\n", .{ sparse, events, cases });
}
test "dense shared path batch publication survives every write and sync cut" {
    try campaign(false);
}
test "sparse sibling batch publication survives every write and sync cut" {
    try campaign(true);
}
