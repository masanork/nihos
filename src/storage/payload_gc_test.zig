const std = @import("std");
const checkpoint = @import("checkpoint_model.zig");
const media = @import("model_media.zig");
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const page = checkpoint.page_bytes;
const Backend = media.Media(14 * page);
const Store = checkpoint.Store(Backend, .{ .leaf_pages = 1, .index_pages = 4, .payload_reserve_pages = 2 });

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
        std.debug.print("PAYLOAD_PIN_COUNTEREXAMPLE error={s}\n", .{@errorName(err)});
        return err;
    };
    try equal(expected.len, n);
    try std.testing.expectEqualSlices(u8, expected, bytes[0..n]);
}

test "nonempty payloads recycle a small volume without a media-sized map" {
    const Roomy = checkpoint.Store(Backend, .{ .leaf_pages = 1, .index_pages = 4 });
    var backend = Backend{};
    var store = Roomy{};
    try store.format(&backend);
    for (0..512) |i| {
        const bytes: [17]u8 = @splat(@truncate(i));
        try put(&store, &bytes);
    }
    const space = try store.payloadSpace();
    try equal(@as(u64, 8), space.usable_pages);
    try equal(@as(u64, 4), space.free_pages);
    try store.collectPayload();
    try equal(@as(u64, 6), (try store.payloadSpace()).free_pages);
    backend.powerLoss();
    var reopened = Roomy{};
    try reopened.recover(&backend);
    const last: [17]u8 = @splat(0xff);
    try object(&reopened, &last);
    try equal(@as(u64, 514), reopened.generation());
    std.debug.print("PAYLOAD_GC_REUSE mutations=512 usable_pages=8 last_object_pages=2 free_after_collection=6\n", .{});
}

test "payload pins impose NoSpace until released and reserved pages stay untouched" {
    var backend = Backend{};
    var store = Store{};
    try store.format(&backend);
    try put(&store, "old");
    const old = try store.pin();
    try put(&store, "middle");
    const middle = try store.pin();
    try put(&store, "current");
    try store.collectPayload();
    const space = try store.payloadSpace();
    try equal(@as(u64, 6), space.usable_pages);
    try equal(@as(u32, 2), space.reserved_pages);
    try equal(@as(u64, 0), space.free_pages);
    try store.begin();
    const events = backend.events;
    try expectError(error.NoSpace, store.put(1, "blocked"));
    try equal(events, backend.events);
    try store.rollback();
    try pinned(&store, old, "old");
    try pinned(&store, middle, "middle");
    try store.release(middle);
    try equal(@as(u64, 2), (try store.payloadSpace()).free_pages);
    try put(&store, "replacement");
    try pinned(&store, old, "old");
    for (backend.stable[Store.payload_end * page ..]) |byte| try equal(@as(u8, 0xff), byte);
    try store.release(old);
}

test "payload reclamation protects every staged key and rollback releases only unpublished ranges" {
    var backend = Backend{};
    var store = Store{};
    try store.format(&backend);
    try put(&store, "old");
    try store.begin();
    try store.put(1, "staged-one");
    try store.put(2, "staged-two");
    try equal(@as(u64, 0), (try store.payloadSpace()).free_pages);
    const events = backend.events;
    try expectError(error.NoSpace, store.put(3, "overflow"));
    try equal(events, backend.events);
    try store.rollback();
    try equal(@as(u64, 4), (try store.payloadSpace()).free_pages);
    try object(&store, "old");
    try put(&store, "reused");
    try object(&store, "reused");
}

test "fragmentation rejects a large allocation and a free run spans bitmap windows" {
    const File = media.Media(24 * page);
    const Windowed = checkpoint.Store(File, .{ .leaf_pages = 1, .index_pages = 4, .payload_window_bytes = 1 });
    var backend = File{};
    var store = Windowed{};
    try store.format(&backend);
    const small: [2 * page + 1]u8 = @splat(0x31);
    try store.begin();
    for (1..4) |key| try store.put(@intCast(key), &small);
    try store.commit();
    try store.begin();
    try store.remove(1);
    try store.remove(3);
    try store.commit();
    try store.collectPayload();
    const fragmented = try store.payloadSpace();
    try equal(@as(u64, 14), fragmented.free_pages);
    try equal(@as(u64, 10), fragmented.largest_run);
    const large: [10 * page + 1]u8 = @splat(0x64);
    try store.begin();
    const events = backend.events;
    try expectError(error.NoSpace, store.put(4, &large));
    try equal(events, backend.events);
    try store.rollback();
    try store.begin();
    try store.remove(2);
    try store.commit();
    try store.collectPayload();
    try store.begin();
    try store.put(4, &large);
    try equal(@as(u32, 2), store.search_windows);
    try store.commit();
    try equal(Windowed.payload_start, (try store.get(4)).first);
    try store.verify(4);
}

fn baseline(backend: *Backend) !void {
    var store = Store{};
    try store.format(backend);
    try put(&store, "old");
    try put(&store, "new");
    try put(&store, "latest");
    backend.powerLoss();
}
fn collectAndReplace(store: *Store, last_ack: *u64) !void {
    try store.collectPayload();
    last_ack.* = store.generation();
    try put(store, "recycled");
    last_ack.* = store.generation();
}

test "payload retirement and recycled range writes preserve the latest acknowledged generation at every cut" {
    var base = Backend{};
    try baseline(&base);
    var cases: usize = 0;
    for ([_]media.Background{ .none, .alternating, .all }) |background| {
        for ([_]media.Order{ .ascending, .descending }) |order| {
            var clean = base;
            clean.background = background;
            clean.order = order;
            var store = Store{};
            try store.recover(&clean);
            var clean_ack: u64 = 4;
            try collectAndReplace(&store, &clean_ack);
            try equal(@as(u64, 6), clean_ack);
            const events = clean.events;
            try equal(@as(usize, 84), events);
            clean.powerLoss();
            var acknowledged = Store{};
            try acknowledged.recover(&clean);
            try equal(@as(u64, 6), acknowledged.generation());
            try object(&acknowledged, "recycled");
            for (0..events) |event| {
                for ([_]usize{ 0, 1, 31, 255, 511, 512 }) |prefix| {
                    var broken = base;
                    broken.background = background;
                    broken.order = order;
                    var interrupted = Store{};
                    try interrupted.recover(&broken);
                    var last_ack: u64 = 4;
                    broken.cut = .{ .event = event, .prefix = prefix };
                    try expectError(error.Io, collectAndReplace(&interrupted, &last_ack));
                    broken.powerLoss();
                    var recovered = Store{};
                    try recovered.recover(&broken);
                    try expect(recovered.generation() >= last_ack and recovered.generation() <= 6);
                    try object(&recovered, if (recovered.generation() == 6) "recycled" else "latest");
                    cases += 1;
                }
            }
        }
    }
    try equal(@as(usize, 3024), cases);
    std.debug.print("PAYLOAD_GC_CAMPAIGN events=84 crash_cases=3024 acknowledged_cases=6\n", .{});
}

test "payload allocator fails closed on a protected leaf read failure" {
    var backend = Backend{};
    try baseline(&backend);
    var store = Store{};
    try store.recover(&backend);
    try store.begin();
    backend.read_error = true;
    const events = backend.events;
    try expectError(error.Io, store.put(1, "cannot-search"));
    try equal(events, backend.events);
    try expectError(error.Faulted, store.begin());
}

test "a pinned payload view stays valid while a different free hole is reused" {
    const Roomy = checkpoint.Store(Backend, .{ .leaf_pages = 1, .index_pages = 4 });
    var backend = Backend{};
    var store = Roomy{};
    try store.format(&backend);
    try put(&store, "old");
    const reader = try store.pin();
    try put(&store, "two");
    try put(&store, "three");
    try put(&store, "four");
    try store.collectPayload();
    try put(&store, "five");
    try pinned(&store, reader, "old");
    try object(&store, "five");
}

test "the retained disk payload survives a replacement and damaged-current-root fallback" {
    var backend = Backend{};
    try baseline(&backend);
    var store = Store{};
    try store.recover(&backend);
    try put(&store, "wrap");
    try store.collectPayload();
    try put(&store, "after");
    try store.begin();
    backend.background = .all;
    try store.put(1, "unpublished");
    backend.powerLoss();
    // Current is generation 7, retained generation 6 contains "wrap".
    backend.stable[page + 17] ^= 1;
    backend.powerLoss();
    var fallback = Store{};
    try fallback.recover(&backend);
    try equal(@as(u64, 6), fallback.generation());
    object(&fallback, "wrap") catch |err| {
        std.debug.print("PAYLOAD_RETAINED_COUNTEREXAMPLE error={s}\n", .{@errorName(err)});
        return err;
    };
}

test "payload reserve geometry and the previous format are rejected without writes" {
    var backend = Backend{};
    try baseline(&backend);
    const WrongReserve = checkpoint.Store(Backend, .{ .leaf_pages = 1, .index_pages = 4 });
    var wrong = WrongReserve{};
    try expectError(error.Corrupt, wrong.recover(&backend));
    for (0..2) |slot| {
        const root = backend.cache[slot * page ..][0..page];
        std.mem.writeInt(u32, root[4..8], 2, .little);
        std.mem.writeInt(u32, root[checkpoint.crc_offset..][0..4], std.hash.Crc32.hash(root[0..checkpoint.crc_offset]), .little);
    }
    backend.stable = backend.cache;
    backend.powerLoss();
    var previous = Store{};
    try expectError(error.Corrupt, previous.recover(&backend));
    try equal(@as(usize, 0), backend.events);
}
