const std = @import("std");
const model = @import("checkpoint_model.zig");
const media = @import("model_media.zig");
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const page = model.page_bytes;
const Backend = media.Media(28 * page);
const Device = struct {
    pub const capacity = Backend.capacity;
    backend: *Backend,
    bytes_read: usize = 0,
    pub fn read(self: *@This(), offset: u64, bytes: []u8) error{Io}!void {
        self.bytes_read += bytes.len;
        return self.backend.read(offset, bytes);
    }
    pub fn write(self: *@This(), offset: u64, bytes: []const u8) error{Io}!void {
        return self.backend.write(offset, bytes);
    }
    pub fn sync(self: *@This()) error{Io}!void {
        return self.backend.sync();
    }
};
const Store = model.Store(Device, .{ .leaf_pages = 2, .index_pages = 8, .payload_reserve_pages = 2, .payload_window_bytes = 1, .leaf_cache_pages = 2 });
const budget = model.SearchBudget{ .leaf_visits = 1, .bitmap_pages = 1 };
fn put(store: *Store, data: []const u8) !void {
    try store.begin();
    try store.put(1, data);
    try store.commit();
}
fn fill(store: *Store) !void {
    for (0..8) |i| {
        const bytes: [17]u8 = @splat(@truncate(i));
        try put(store, &bytes);
    }
    try store.collectPayload();
}
fn step(store: *Store, device: *Device) !model.SearchResult {
    const before = device.bytes_read;
    const result = try store.stepPayloadSearch(budget);
    try expect(device.bytes_read - before <= page);
    try expect(store.step_leaf_visits <= budget.leaf_visits);
    try expect(store.step_bitmap_pages <= budget.bitmap_pages);
    return result;
}

test "allocation search yields within both budgets and prepared put does not search again" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    try store.format(&device);
    try fill(&store);
    const reader = try store.pin();
    try store.begin();
    try store.beginPayloadSearch(2);
    const events = backend.events;
    var calls: usize = 0;
    while (true) {
        calls += 1;
        switch (try step(&store, &device)) {
            .pending => {
                var byte: [1]u8 = undefined;
                try equal(@as(usize, 1), try store.readPinned(reader, 1, 0, &byte));
                try equal(@as(u8, 7), byte[0]);
            },
            .found => |first| {
                try equal(Store.payload_start, first);
                break;
            },
            else => return error.BadSearchResult,
        }
    }
    try expect(calls > 1);
    try equal(events, backend.events);
    const windows = store.search_windows;
    const reads = store.search_leaf_reads;
    try store.putPrepared(1, "prepared");
    try equal(windows, store.search_windows);
    try equal(reads, store.search_leaf_reads);
    try store.commit();
    var bytes: [8]u8 = undefined;
    try equal(bytes.len, try store.read(1, 0, &bytes));
    try std.testing.expectEqualSlices(u8, "prepared", &bytes);
    std.debug.print("SEARCH_BUDGET calls={d} max_leaf_visits=1 max_bitmap_pages=1 max_metadata_read_bytes=4096\n", .{calls});
}

test "space search resumes across windows and agrees with the blocking wrapper" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    try store.format(&device);
    try fill(&store);
    const expected = try store.payloadSpace();
    try store.beginPayloadSpace();
    var calls: usize = 0;
    const actual = while (true) {
        calls += 1;
        switch (try step(&store, &device)) {
            .pending => {},
            .space => |space| break space,
            else => return error.BadSearchResult,
        }
    };
    try expect(calls > 16);
    try equal(expected.free_pages, actual.free_pages);
    try equal(expected.largest_run, actual.largest_run);
    try equal(@as(u32, 2), store.search_windows);
}

test "reader and writer mutations invalidate pending and completed searches" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    try store.format(&device);
    try put(&store, "old");
    try store.beginPayloadSpace();
    _ = try step(&store, &device);
    const reader = try store.pin();
    try expectError(error.InvalidSearch, store.stepPayloadSearch(budget));
    try store.beginPayloadSpace();
    try store.release(reader);
    try expectError(error.InvalidSearch, store.stepPayloadSearch(budget));
    try store.beginPayloadSpace();
    try store.begin();
    try expectError(error.InvalidSearch, store.stepPayloadSearch(budget));
    try store.beginPayloadSearch(2);
    switch (try store.stepPayloadSearch(budget)) {
        .found => {},
        else => return error.ExpectedTailAllocation,
    }
    const newer = try store.pin();
    const events = backend.events;
    try expectError(error.SearchRequired, store.putPrepared(1, "changed"));
    try equal(events, backend.events);
    try store.release(newer);
    try store.beginPayloadSpace();
    try store.rollback();
    try expectError(error.InvalidSearch, store.stepPayloadSearch(budget));
    try store.begin();
    try store.beginPayloadSpace();
    try store.put(1, "next");
    try expectError(error.InvalidSearch, store.stepPayloadSearch(budget));
    try store.beginPayloadSpace();
    try store.remove(1);
    try expectError(error.InvalidSearch, store.stepPayloadSearch(budget));
    try store.beginPayloadSpace();
    try store.commit();
    try expectError(error.InvalidSearch, store.stepPayloadSearch(budget));
}

test "invalid budgets cancel and mismatched prepared payloads have no write side effects" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    try store.format(&device);
    try store.begin();
    try store.beginPayloadSearch(2);
    const events = backend.events;
    try expectError(error.InvalidArgument, store.stepPayloadSearch(.{ .leaf_visits = 0 }));
    try expectError(error.InvalidArgument, store.stepPayloadSearch(.{ .bitmap_pages = 0 }));
    try expectError(error.InvalidArgument, store.stepPayloadSearch(.{ .leaf_visits = 65 }));
    try expectError(error.InvalidArgument, store.stepPayloadSearch(.{ .bitmap_pages = 4097 }));
    const big: [2 * page]u8 = @splat(0x31);
    try expectError(error.SearchRequired, store.putPrepared(1, &big));
    try equal(events, backend.events);
    store.cancelPayloadSearch();
    try expectError(error.InvalidSearch, store.stepPayloadSearch(budget));
}

test "metadata cache avoids backend reads and still checks cached page integrity" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    try store.format(&device);
    try put(&store, "old");
    store.dropMetadataCache();
    device.bytes_read = 0;
    _ = try store.get(1);
    try equal(@as(usize, page), device.bytes_read);
    device.bytes_read = 0;
    _ = try store.get(1);
    try equal(@as(usize, 0), device.bytes_read);
    store.leaf_cache[0].bytes[24] ^= 1;
    try expectError(error.Corrupt, store.get(1));
    try expectError(error.Faulted, store.begin());
}

test "cold cache invalidation exposes backend faults and page reuse returns current data" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    try store.format(&device);
    for (0..32) |i| {
        const bytes: [17]u8 = @splat(@truncate(i));
        try put(&store, &bytes);
        try store.collectPayload();
        var readback: [17]u8 = undefined;
        try equal(readback.len, try store.read(1, 0, &readback));
        try std.testing.expectEqualSlices(u8, &bytes, &readback);
    }
    backend.read_error = true;
    _ = try store.get(1); // Validated immutable metadata is already cached.
    store.dropMetadataCache();
    try expectError(error.Io, store.get(1));
}

test "128 logical leaf cache has a fixed explicit RAM envelope at sixteen GiB" {
    const file = @import("file_media.zig");
    const Plain = model.Store(file.Media(16 * 1024 * 1024 * 1024), .{});
    const Small = model.Store(file.Media(1024 * 1024 * 1024), .{ .leaf_cache_pages = 128 });
    const Cached = model.Store(file.Media(16 * 1024 * 1024 * 1024), .{ .leaf_cache_pages = 128 });
    try equal(@sizeOf(Small), @sizeOf(Cached));
    try equal(@as(usize, (page + 16) * 128), @sizeOf(Cached) - @sizeOf(Plain));
    try expect(@sizeOf(Plain) <= 32 * 1024);
    try expect(@sizeOf(Cached) <= 640 * 1024);
    std.debug.print("SEARCH_CACHE_BUDGET plain_state_bytes={d} cached_state_bytes={d} data_bytes=524288 tags_bytes=2048\n", .{ @sizeOf(Plain), @sizeOf(Cached) });
}
