const std = @import("std");
const checkpoint = @import("checkpoint_model.zig");
const media = @import("model_media.zig");
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const Backend = media.Media(24 * checkpoint.page_bytes);
const Store = checkpoint.Store(Backend, .{ .leaf_pages = 1, .index_pages = 3 });

fn put(store: anytype, data: []const u8) !void {
    try store.begin();
    try store.put(1, data);
    try store.commit();
}
fn object(store: anytype, expected: []const u8) !void {
    var bytes: [32]u8 = undefined;
    try equal(expected.len, try store.read(1, 0, &bytes));
    try std.testing.expectEqualSlices(u8, expected, bytes[0..expected.len]);
}
fn pinned(store: anytype, reader: checkpoint.Reader, expected: []const u8) !void {
    var bytes: [32]u8 = undefined;
    const n = store.readPinned(reader, 1, 0, &bytes) catch |err| {
        std.debug.print("PIN_COUNTEREXAMPLE current_generation={d} error={s}\n", .{ store.generation(), @errorName(err) });
        return err;
    };
    try equal(expected.len, n);
    try std.testing.expectEqualSlices(u8, expected, bytes[0..n]);
}
fn baseline(backend: *Backend) !void {
    var store = Store{};
    try store.format(backend);
    try put(&store, "old");
    try put(&store, "new");
    backend.powerLoss();
}
fn collectAndReplace(store: *Store) !void {
    const space = try store.collectIndex();
    try equal(@as(u32, 2), space.available_pages);
    try put(store, "next");
}

test "index reachability reuses a tiny pool beyond the old append limit" {
    const Tiny = checkpoint.Store(Backend, .{ .leaf_pages = 1, .index_pages = 3 });
    var backend = Backend{};
    var store = Tiny{};
    try store.format(&backend);
    const payload_next = Tiny.payload_start;
    for (0..6000) |i| {
        try store.begin();
        if (i % 2 == 0) try store.put(1, "") else try store.remove(1);
        try store.commit();
    }
    const space = try store.indexSpace();
    try equal(@as(u32, 2), space.protected_pages);
    try equal(@as(u32, 1), space.available_pages);
    try equal(payload_next, store.current.payload_next);
    backend.powerLoss();
    var reopened = Tiny{};
    try reopened.recover(&backend);
    try equal(@as(u64, 6001), reopened.generation());
    try expectError(error.NotFound, reopened.get(1));
    std.debug.print("INDEX_GC_REUSE mutations=6000 pool_pages=3 protected_pages=2 free_pages=1 generation={d}\n", .{reopened.generation()});
}

test "pinned snapshots survive metadata reuse and stale reader handles cannot be reused" {
    var backend = Backend{};
    var store = Store{};
    try store.format(&backend);
    try put(&store, "old");
    const old = try store.pin();
    try put(&store, "new");
    const current = try store.pin();
    try expectError(error.ReaderLimit, store.pin());
    _ = try store.collectIndex();
    try put(&store, "next");
    try pinned(&store, old, "old");
    try pinned(&store, current, "new");
    try object(&store, "next");
    try store.release(old);
    try expectError(error.InvalidReader, store.release(old));
    const replacement = try store.pin();
    try equal(old.slot, replacement.slot);
    try expect(old.token != replacement.token);
    var byte: [1]u8 = undefined;
    try expectError(error.InvalidReader, store.readPinned(old, 1, 0, &byte));
    try store.release(current);
    _ = try store.collectIndex();
    try put(&store, "last");
    try pinned(&store, replacement, "next");
    try object(&store, "last");
    try store.release(replacement);
}

test "root-only collection runs with no free leaf page while pins enforce backpressure" {
    const Tight = checkpoint.Store(Backend, .{ .leaf_pages = 1, .index_pages = 2 });
    var backend = Backend{};
    var store = Tight{};
    try store.format(&backend);
    try put(&store, "old");
    const old = try store.pin();
    try put(&store, "new");
    try equal(@as(u32, 0), (try store.indexSpace()).available_pages);
    try store.begin();
    const events = backend.events;
    try expectError(error.NoSpace, store.put(1, "blocked"));
    try equal(events, backend.events);
    try store.rollback();
    try equal(@as(u32, 0), (try store.collectIndex()).available_pages);
    try pinned(&store, old, "old");
    try store.release(old);
    try equal(@as(u32, 1), (try store.indexSpace()).available_pages);
    try put(&store, "next");
    try equal(@as(u32, 0), (try store.indexSpace()).available_pages);
    try equal(@as(u32, 1), (try store.collectIndex()).available_pages);
    try object(&store, "next");
}

test "rollback reclaims only staged leaves and faulted stores still release pins" {
    var backend = Backend{};
    var store = Store{};
    try store.format(&backend);
    try put(&store, "old");
    const old = try store.pin();
    for (0..16) |_| {
        try store.begin();
        try store.put(1, "");
        try equal(@as(u32, 1), (try store.indexSpace()).available_pages);
        try store.rollback();
        try equal(@as(u32, 2), (try store.indexSpace()).available_pages);
    }
    try pinned(&store, old, "old");
    backend.read_error = true;
    var byte: [1]u8 = undefined;
    try expectError(error.Io, store.readPinned(old, 1, 0, &byte));
    try store.release(old);
    try expectError(error.Faulted, store.pin());
}

test "both valid disk roots survive an unpublished replacement before fallback" {
    var backend = Backend{};
    try baseline(&backend);
    backend.background = .all;
    var store = Store{};
    try store.recover(&backend);
    try store.begin();
    try store.put(1, "unpublished");
    const events = backend.events;
    try expectError(error.Busy, store.collectIndex());
    try equal(events, backend.events);
    // A separate damaged-current-root test asks the older disk checkpoint to
    // remain readable even though unfenced new writes have reached the media.
    backend.powerLoss();
    backend.stable[checkpoint.page_bytes + 17] ^= 1;
    backend.powerLoss();
    var fallback = Store{};
    fallback.recover(&backend) catch |err| {
        std.debug.print("RETAINED_ROOT_COUNTEREXAMPLE error={s}\n", .{@errorName(err)});
        return err;
    };
    try equal(@as(u64, 2), fallback.generation());
    try object(&fallback, "old");
}

test "every retirement and recycled leaf write cut preserves the latest acknowledged state" {
    var base = Backend{};
    try baseline(&base);
    var cases: usize = 0;
    var clean_events: usize = 0;
    for ([_]media.Background{ .none, .alternating, .all }) |background| {
        for ([_]media.Order{ .ascending, .descending }) |order| {
            var clean = base;
            clean.background = background;
            clean.order = order;
            var store = Store{};
            try store.recover(&clean);
            try collectAndReplace(&store);
            clean_events = clean.events;
            try equal(@as(usize, 84), clean_events);
            clean.powerLoss();
            var acknowledged = Store{};
            try acknowledged.recover(&clean);
            try equal(@as(u64, 5), acknowledged.generation());
            try object(&acknowledged, "next");
            for (0..clean_events) |event| {
                for ([_]usize{ 0, 1, 31, 255, 511, 512 }) |prefix| {
                    var broken = base;
                    broken.background = background;
                    broken.order = order;
                    var interrupted = Store{};
                    try interrupted.recover(&broken);
                    broken.cut = .{ .event = event, .prefix = prefix };
                    try expectError(error.Io, collectAndReplace(&interrupted));
                    try expectError(error.Faulted, interrupted.begin());
                    broken.powerLoss();
                    var recovered = Store{};
                    try recovered.recover(&broken);
                    try expect(recovered.generation() >= 3 and recovered.generation() <= 5);
                    try object(&recovered, if (recovered.generation() == 5) "next" else "new");
                    cases += 1;
                }
            }
        }
    }
    try equal(@as(usize, 3024), cases);
    std.debug.print("INDEX_GC_CAMPAIGN events={d} crash_cases={d} acknowledged_cases=6\n", .{ clean_events, cases });
}
