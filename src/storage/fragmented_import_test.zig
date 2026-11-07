//! Experimental mapped-object import using bounded scattered searches. This
//! is a host model, not a transaction-wide capacity reservation or SD driver.
const std = @import("std");
const model = @import("checkpoint_model.zig");
const media = @import("model_media.zig");
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
    try std.testing.expectEqual(@as(u64, 1), space.largest_run);
    try std.testing.expectEqual(@as(u64, 10), space.free_pages);
}
fn search(store: *Store, pages: u64, headroom: u64) !void {
    try store.beginMappedSearchWithHeadroom(pages, headroom);
    while (true) switch (try store.stepPayloadSearch(.{ .leaf_visits = 1, .bitmap_pages = 1 })) {
        .pending => try std.testing.expect(store.step_leaf_visits <= 1 and store.step_bitmap_pages <= 1),
        .found => return,
        .no_space => return error.NoSpace,
        else => return error.InvalidSearch,
    };
}
const payload: [page + 3]u8 = bytes: {
    @setEvalBranchQuota(10000);
    var b: [page + 3]u8 = undefined;
    for (&b, 0..) |*v, i| v.* = @truncate(i *% 17 +% 23);
    break :bytes b;
};
fn import(store: *Store) !void {
    var scratch = model.MapScratch{};
    try store.begin();
    try store.put(2, "");
    try search(store, try store.mappedResizePages(2, payload.len, &scratch), 1);
    try store.resizeMappedPrepared(2, payload.len, &scratch);
    for (0..2) |i| {
        const offset = i * page;
        const patch = [_]model.MappedPatch{.{ .offset = offset, .bytes = payload[offset..@min(offset + page, payload.len)] }};
        try search(store, try Store.mappedBatchPages(payload.len, &patch), 1);
        try store.patchMappedBatchPrepared(2, &patch, &scratch);
    }
    try store.commit();
}
fn verify(store: *Store, published: bool) !void {
    if (!published) {
        try std.testing.expectError(error.NotFound, store.get(2));
    } else {
        var buf: [payload.len]u8 = undefined;
        try std.testing.expectEqual(buf.len, try store.read(2, 0, &buf));
        try std.testing.expectEqualSlices(u8, &payload, &buf);
        try store.verify(2);
    }
    for (0..10) |i| {
        var b: [1]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 1), try store.read(1, i * page, &b));
        try std.testing.expectEqual(@as(u8, @intCast(0x40 + i)), b[0]);
    }
}

test "fragmented mapped import publishes complete object only at commit" {
    var backend = Backend{};
    var store = Store{};
    try fragmented(&store, &backend);
    const reader = try store.pin();
    var scratch = model.MapScratch{};
    try store.begin();
    try std.testing.expectError(error.NoSpace, store.beginStream(2, payload.len));
    try store.put(2, "");
    try search(&store, try store.mappedResizePages(2, payload.len, &scratch), 1);
    try store.resizeMappedPrepared(2, payload.len, &scratch);
    for (0..2) |i| {
        const offset = i * page;
        const patch = [_]model.MappedPatch{.{ .offset = offset, .bytes = payload[offset..@min(offset + page, payload.len)] }};
        try search(&store, try Store.mappedBatchPages(payload.len, &patch), 1);
        try store.patchMappedBatchPrepared(2, &patch, &scratch);
        try std.testing.expectError(error.NotFound, store.get(2));
        try std.testing.expectError(error.NotFound, store.getPinned(reader, 2));
    }
    try store.commit();
    try verify(&store, true);
    try std.testing.expectError(error.NotFound, store.getPinned(reader, 2));
    try store.release(reader);
}

test "failed mid-import admission rolls back all staged pages" {
    var backend = Backend{};
    var store = Store{};
    try fragmented(&store, &backend);
    var scratch = model.MapScratch{};
    try store.begin();
    try store.put(2, "");
    try search(&store, try store.mappedResizePages(2, payload.len, &scratch), 1);
    try store.resizeMappedPrepared(2, payload.len, &scratch);
    const first = [_]model.MappedPatch{.{ .offset = 0, .bytes = payload[0..page] }};
    try search(&store, try Store.mappedBatchPages(payload.len, &first), 1);
    try store.patchMappedBatchPrepared(2, &first, &scratch);
    const last = [_]model.MappedPatch{.{ .offset = page, .bytes = payload[page..] }};
    try std.testing.expectError(error.NoSpace, search(&store, try Store.mappedBatchPages(payload.len, &last), 32));
    try store.rollback();
    try verify(&store, false);
    backend.powerLoss();
    var recovered = Store{};
    try recovered.recover(&backend);
    try verify(&recovered, false);
}

test "interrupted fragmented import recovers old or fully published state" {
    var base = Backend{};
    var initial = Store{};
    try fragmented(&initial, &base);
    base.powerLoss();
    var clean = base;
    var store = Store{};
    try store.recover(&clean);
    try import(&store);
    const events = clean.events;
    clean.powerLoss();
    var recovered_clean = Store{};
    try recovered_clean.recover(&clean);
    try verify(&recovered_clean, true);
    var cases: usize = 0;
    for ([_]media.Background{ .none, .all }) |background| {
        for (0..events) |event| {
            var broken = base;
            broken.background = background;
            var attempt = Store{};
            try attempt.recover(&broken);
            broken.cut = .{ .event = event, .prefix = 31 };
            try std.testing.expectError(error.Io, import(&attempt));
            broken.powerLoss();
            var recovered = Store{};
            try recovered.recover(&broken);
            const value = recovered.get(2) catch |err| switch (err) {
                error.NotFound => null,
                else => return err,
            };
            try verify(&recovered, value != null);
            cases += 1;
        }
    }
    std.debug.print("FRAGMENTED_IMPORT events={d} crash_cases={d}\n", .{ events, cases });
}
