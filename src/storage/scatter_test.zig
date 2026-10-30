const std = @import("std");
const model = @import("checkpoint_model.zig");
const media = @import("model_media.zig");
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const page = model.page_bytes;
const Backend = media.Media(32 * page);
const Store = model.Store(Backend, .{ .leaf_pages = 1, .index_pages = 8, .leaf_cache_pages = 1, .payload_window_bytes = 1 });
fn fragmented(store: *Store, backend: *Backend) !void {
    var scratch = model.MapScratch{};
    try store.format(backend);
    try store.begin();
    try store.put(1, "");
    try store.commit();
    try store.begin();
    try store.resizeMapped(1, 10 * page, &scratch);
    try store.commit();
    for (0..10) |i| {
        const byte: [1]u8 = .{@intCast(0x40 + i)};
        try store.begin();
        try store.patchMappedPage(1, i * page, &byte);
        try store.commit();
    }
    const space = try store.payloadSpace();
    try equal(@as(u64, 1), space.largest_run);
    try equal(@as(u64, 10), space.free_pages);
}
fn search(store: *Store, pages: u64) !void {
    try store.beginMappedSearch(pages);
    while (true) switch (try store.stepPayloadSearch(.{ .leaf_visits = 1, .bitmap_pages = 1 })) {
        .pending => {
            try expect(store.step_leaf_visits <= 1 and store.step_bitmap_pages <= 1);
        },
        .found => break,
        else => return error.NoMappedSpace,
    };
}
const patches = [_]model.MappedPatch{ .{ .offset = 0, .bytes = "X" }, .{ .offset = 9 * page, .bytes = "Z" } };
fn update(store: *Store, comptime resize: bool) !void {
    var scratch = model.MapScratch{};
    try store.begin();
    if (resize) {
        try search(store, try store.mappedResizePages(1, 4099, &scratch));
        try store.resizeMappedPrepared(1, 4099, &scratch);
    } else {
        try search(store, try Store.mappedBatchPages(10 * page, &patches));
        try store.patchMappedBatchPrepared(1, &patches, &scratch);
    }
    try store.commit();
}
fn check(store: *Store, comptime resize: bool, changed: bool) !void {
    const length: u64 = if (resize and changed) 4099 else 10 * page;
    try equal(length, (try store.get(1)).length);
    for (0..if (resize and changed) @as(usize, 2) else 10) |i| {
        var byte: [1]u8 = undefined;
        _ = try store.read(1, i * page, &byte);
        try equal(@as(u8, if (!resize and changed and i == 0) 'X' else if (!resize and changed and i == 9) 'Z' else @intCast(0x40 + i)), byte[0]);
    }
    try store.verify(1);
}
test "scattered batch uses isolated holes while contiguous admission fails and old reader survives" {
    var backend = Backend{};
    var store = Store{};
    var scratch = model.MapScratch{};
    try fragmented(&store, &backend);
    const reader = try store.pin();
    try store.begin();
    try expectError(error.NoSpace, store.patchMappedBatch(1, &patches, &scratch));
    try search(&store, 3);
    try equal(@as(u8, 3), store.search.selected);
    try equal(@as(u64, 10), store.search.locations[0]);
    try equal(@as(u64, 12), store.search.locations[1]);
    try equal(@as(u64, 14), store.search.locations[2]);
    try store.patchMappedBatchPrepared(1, &patches, &scratch);
    try store.commit();
    try check(&store, false, true);
    var byte: [1]u8 = undefined;
    _ = try store.readPinned(reader, 1, 0, &byte);
    try equal(@as(u8, 0x40), byte[0]);
    _ = try store.readPinned(reader, 1, 9 * page, &byte);
    try equal(@as(u8, 0x49), byte[0]);
    try store.collectPayload();
    const before = (try store.payloadSpace()).free_pages;
    try store.release(reader);
    try equal(before + 3, (try store.payloadSpace()).free_pages);
}
test "scattered resize clears tails and omitted pages without resurrecting old bytes" {
    var backend = Backend{};
    var store = Store{};
    var scratch = model.MapScratch{};
    try fragmented(&store, &backend);
    const reader = try store.pin();
    try update(&store, true);
    try check(&store, true, true);
    try store.begin();
    try search(&store, try store.mappedResizePages(1, 10 * page, &scratch));
    try store.resizeMappedPrepared(1, 10 * page, &scratch);
    try store.commit();
    var bytes: [8]u8 = @splat(0xff);
    _ = try store.read(1, 9 * page, &bytes);
    try std.testing.expectEqualSlices(u8, &@as([8]u8, @splat(0)), &bytes);
    _ = try store.readPinned(reader, 1, 9 * page, bytes[0..1]);
    try equal(@as(u8, 0x49), bytes[0]);
    try store.release(reader);
    try store.verify(1);
}
test "scattered plans cannot authorize legacy extents or survive reader-state mutation" {
    var backend = Backend{};
    var store = Store{};
    var scratch = model.MapScratch{};
    try fragmented(&store, &backend);
    try store.begin();
    try search(&store, 3);
    const blob: [5003]u8 = @splat(0x99);
    try expectError(error.SearchRequired, store.putPrepared(2, &blob));
    try expectError(error.SearchRequired, store.beginStreamPrepared(2, blob.len));
    try search(&store, 2);
    try expectError(error.SearchRequired, store.patchMappedPagePrepared(1, 0, "x"));
    try search(&store, 3);
    const reader = try store.pin();
    try expectError(error.SearchRequired, store.patchMappedBatchPrepared(1, &patches, &scratch));
    try store.release(reader);
    try expectError(error.InvalidArgument, store.beginMappedSearch(model.max_mapped_allocation_pages + 1));
    try store.rollback();
    try check(&store, false, false);
}
test "scattered headroom admission counts isolated free pages without allocating its reserve" {
    var backend = Backend{};
    var store = Store{};
    var scratch = model.MapScratch{};
    try fragmented(&store, &backend);
    try store.begin();
    try store.beginMappedSearchWithHeadroom(3, 8);
    while (true) switch (try store.stepPayloadSearch(.{ .leaf_visits = 1, .bitmap_pages = 1 })) {
        .pending => {},
        .no_space => break,
        else => return error.AdmittedWithoutHeadroom,
    };
    try check(&store, false, false);
    try store.beginMappedSearchWithHeadroom(3, 7);
    while (true) switch (try store.stepPayloadSearch(.{ .leaf_visits = 1, .bitmap_pages = 1 })) {
        .pending => {},
        .found => break,
        else => return error.RejectedWithHeadroom,
    };
    try equal(@as(u8, 3), store.search.selected);
    try store.patchMappedBatchPrepared(1, &patches, &scratch);
    try equal(@as(u64, 7), (try store.payloadSpace()).free_pages);
    try store.rollback();
    try equal(@as(u64, 10), (try store.payloadSpace()).free_pages);
    try store.begin();
    try store.beginMappedSearchWithHeadroom(1, std.math.maxInt(u64));
    try expect(try store.stepPayloadSearch(.{}) == .no_space);
    try store.rollback();
}
fn campaign(comptime resize: bool) !void {
    var base = Backend{};
    var initial = Store{};
    try fragmented(&initial, &base);
    base.powerLoss();
    var cases: usize = 0;
    var events: usize = 0;
    for ([_]media.Background{ .none, .alternating, .all }) |background| for ([_]media.Order{ .ascending, .descending }) |order| {
        var clean = base;
        clean.background = background;
        clean.order = order;
        var store = Store{};
        try store.recover(&clean);
        try update(&store, resize);
        events = clean.events;
        clean.powerLoss();
        var acknowledged = Store{};
        try acknowledged.recover(&clean);
        try equal(@as(u64, 14), acknowledged.generation());
        try check(&acknowledged, resize, true);
        for (0..events) |event| for ([_]usize{ 0, 1, 31, 255, 511, 512 }) |prefix| {
            var broken = base;
            broken.background = background;
            broken.order = order;
            var interrupted = Store{};
            try interrupted.recover(&broken);
            broken.cut = .{ .event = event, .prefix = prefix };
            try expectError(error.Io, update(&interrupted, resize));
            broken.powerLoss();
            var recovered = Store{};
            try recovered.recover(&broken);
            try expect(recovered.generation() == 13 or recovered.generation() == 14);
            try check(&recovered, resize, recovered.generation() == 14);
            cases += 1;
        };
    };
    try equal(@as(usize, if (resize) 66 else 82), events);
    try equal(@as(usize, if (resize) 2376 else 2952), cases);
    std.debug.print("SCATTER_CAMPAIGN resize={} events={d} crash_cases={d} acknowledged_cases=6\n", .{ resize, events, cases });
}
test "scattered batch publication survives every sector and sync cut" {
    try campaign(false);
}
test "scattered resize publication survives every sector and sync cut" {
    try campaign(true);
}
