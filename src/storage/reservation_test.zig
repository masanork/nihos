const std = @import("std");
const api = @import("checkpoint_service.zig");
const model = api.model;
const media = @import("model_media.zig");
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const page = model.page_bytes;
const Backend = media.Media(96 * page);
const Store = model.Store(Backend, .{ .leaf_pages = 1, .index_pages = 4, .leaf_cache_pages = 1 });
const Wider = model.Store(Backend, .{ .leaf_pages = 1, .index_pages = 5, .leaf_cache_pages = 1 });
const Queues = api.Queues(@import("../kernel/spsc_ring.zig"));
fn seed(store: anytype, backend: *Backend) !void {
    var scratch = model.MapScratch{};
    try store.format(backend);
    try store.begin();
    try store.put(1, "");
    try store.put(2, "");
    try store.commit();
    try store.begin();
    try store.resizeMapped(1, 2 * page, &scratch);
    try store.resizeMapped(2, page, &scratch);
    try store.commit();
    try store.collectPayload();
}
fn request(owner: anytype, handle: api.Handle, op: api.Operation) api.Request {
    return .{ .epoch = owner.epoch, .sequence = owner.next_sequence, .handle = handle, .operation = @backingInt(op) };
}
fn send(owner: anytype, queues: *Queues, req: api.Request) !api.Response {
    try expect(queues.requests.tryPush(req));
    for (0..10000) |_| switch (owner.step(queues, .{ .leaf_visits = 1, .bitmap_pages = 1 })) {
        .idle => return error.UnexpectedIdle,
        .pending => {},
        .completed => return queues.responses.tryPop() orelse error.MissingReply,
    };
    return error.DidNotFinish;
}
fn write(owner: anytype, queues: *Queues, handle: api.Handle, offset: u64, byte: u8) !api.Response {
    var req = request(owner, handle, .write);
    req.offset = offset;
    req.length = 1;
    req.data[0] = byte;
    return send(owner, queues, req);
}
fn pinned(store: anytype, reader: model.Reader, expected: u8) !void {
    var byte: [1]u8 = undefined;
    _ = try store.readPinned(reader, 1, 0, &byte);
    try equal(expected, byte[0]);
}
test "index reserve and quiescent retirement preserve old readers and recover admission after release" {
    var backend = Backend{};
    var store = Store{};
    try seed(&store, &backend);
    const reader = try store.pin();
    var owner = try api.Owner(Store).init(&store, 11);
    var queues = Queues{};
    var handle = try owner.grant(1, true);
    owner.index_headroom = 2;
    owner.payload_headroom = 4;
    try equal(api.Status.ok, (try write(&owner, &queues, handle, 0, 'A')).status);
    _ = try send(&owner, &queues, request(&owner, handle, .sync));
    try equal(@as(u32, 2), (try store.indexSpace()).available_pages);
    const before = backend.events;
    try equal(api.Status.no_space, (try write(&owner, &queues, handle, 0, 'B')).status);
    try equal(before, backend.events);
    try expectError(error.Busy, owner.retirePrevious(&queues));
    try equal(before, backend.events);
    _ = try owner.clientExited(11, &queues);
    const payload_before = (try store.payloadSpace()).free_pages;
    const still_pinned = try owner.retirePrevious(&queues);
    try equal(@as(u32, 2), still_pinned.available_pages);
    try equal(payload_before, (try store.payloadSpace()).free_pages);
    try pinned(&store, reader, 0);
    try equal(store.generation(), owner.last_durable_generation);
    try store.release(reader);
    const freed = try owner.retirePrevious(&queues);
    try equal(@as(u32, 3), freed.available_pages);
    try expect((try store.payloadSpace()).free_pages > payload_before);
    try expect(owner.rebind(12, &queues));
    try equal(@as(u32, 0), owner.index_headroom);
    owner.index_headroom = 2;
    owner.payload_headroom = 4;
    handle = try owner.grant(1, true);
    try equal(api.Status.ok, (try write(&owner, &queues, handle, 0, 'B')).status);
    const synced = try send(&owner, &queues, request(&owner, handle, .sync));
    try equal(store.generation(), synced.generation);
    backend.powerLoss();
    var recovered = Store{};
    try recovered.recover(&backend);
    var byte: [1]u8 = undefined;
    _ = try recovered.read(1, 0, &byte);
    try equal(@as(u8, 'B'), byte[0]);
}
test "one free index leaf cannot replay multiple writes with two pinned old roots" {
    var backend = Backend{};
    var store = Store{};
    try seed(&store, &backend);
    const oldest = try store.pin();
    var owner = try api.Owner(Store).init(&store, 11);
    var queues = Queues{};
    var handle = try owner.grant(1, true);
    _ = try write(&owner, &queues, handle, 0, 'A');
    _ = try send(&owner, &queues, request(&owner, handle, .sync));
    _ = try owner.clientExited(11, &queues);
    const older = try store.pin();
    try expect(owner.rebind(12, &queues));
    handle = try owner.grant(1, true);
    _ = try write(&owner, &queues, handle, 0, 'B');
    _ = try send(&owner, &queues, request(&owner, handle, .sync));
    try equal(@as(u32, 1), (try store.indexSpace()).available_pages);
    try equal(api.Status.ok, (try write(&owner, &queues, handle, 0, 'R')).status);
    const before = backend.events;
    try equal(api.Status.no_space, (try write(&owner, &queues, handle, page, 'S')).status);
    try equal(before, backend.events);
    try pinned(&store, oldest, 0);
    try pinned(&store, older, 'A');
    try equal(api.Exit.cancelled_staging, try owner.clientExited(12, &queues));
    try store.release(oldest);
    try store.release(older);
    _ = try owner.retirePrevious(&queues);
    try equal(@as(u32, 3), (try store.indexSpace()).available_pages);
}
test "two reserved index pages permit replay and later journal cleanup with both readers pinned" {
    var backend = Backend{};
    var store = Wider{};
    try seed(&store, &backend);
    const oldest = try store.pin();
    var owner = try api.Owner(Wider).init(&store, 11);
    var queues = Queues{};
    var handle = try owner.grant(1, true);
    owner.index_headroom = 2;
    _ = try write(&owner, &queues, handle, 0, 'A');
    _ = try send(&owner, &queues, request(&owner, handle, .sync));
    _ = try owner.clientExited(11, &queues);
    const older = try store.pin();
    try expect(owner.rebind(12, &queues));
    handle = try owner.grant(1, true);
    owner.index_headroom = 2;
    _ = try write(&owner, &queues, handle, 0, 'B');
    _ = try send(&owner, &queues, request(&owner, handle, .sync));
    try equal(@as(u32, 2), (try store.indexSpace()).available_pages);
    _ = try owner.clientExited(12, &queues);
    try expect(owner.rebind(13, &queues)); // trusted recovery binding, zero reserve
    handle = try owner.grant(1, true);
    try equal(api.Status.ok, (try write(&owner, &queues, handle, 0, 'R')).status);
    try equal(api.Status.ok, (try write(&owner, &queues, handle, page, 'S')).status);
    _ = try send(&owner, &queues, request(&owner, handle, .sync));
    const journal = try owner.grant(2, true);
    var truncate = request(&owner, journal, .truncate);
    truncate.offset = 0;
    try equal(api.Status.ok, (try send(&owner, &queues, truncate)).status);
    try equal(api.Status.ok, (try send(&owner, &queues, request(&owner, journal, .sync))).status);
    try pinned(&store, oldest, 0);
    try pinned(&store, older, 'A');
    try equal(@as(u64, 0), (try store.get(2)).length);
    try store.verify(1);
}
test "maintenance rejects live staging or queued work and does not publish it" {
    var backend = Backend{};
    var store = Store{};
    try seed(&store, &backend);
    var owner = try api.Owner(Store).init(&store, 11);
    var queues = Queues{};
    const handle = try owner.grant(1, true);
    _ = try write(&owner, &queues, handle, 0, 'X');
    const before = backend.events;
    try expectError(error.Busy, owner.retirePrevious(&queues));
    try equal(before, backend.events);
    _ = try owner.clientExited(11, &queues);
    try expect(queues.requests.tryPush(.{ .epoch = 1, .sequence = 99 }));
    try expectError(error.Busy, owner.retirePrevious(&queues));
    _ = queues.requests.tryPop();
    try expect(queues.responses.tryPush(.{}));
    try expectError(error.Busy, owner.retirePrevious(&queues));
    _ = queues.responses.tryPop();
    try store.begin();
    try expectError(error.Busy, owner.retirePrevious(&queues));
    try store.rollback();
    _ = try owner.retirePrevious(&queues);
    var byte: [1]u8 = undefined;
    _ = try store.read(1, 0, &byte);
    try equal(@as(u8, 0), byte[0]);
}
fn retirementCampaign(comptime cancelled: bool) !void {
    var base = Backend{};
    var initial = Store{};
    try seed(&initial, &base);
    const reader = try initial.pin();
    try initial.begin();
    try initial.patchMappedPage(1, 0, "A");
    try initial.commit();
    base.powerLoss();
    if (cancelled) {
        var owner = try api.Owner(Store).init(&initial, 11);
        var queues = Queues{};
        const handle = try owner.grant(1, true);
        try equal(api.Status.ok, (try write(&owner, &queues, handle, 0, 'T')).status);
        try equal(api.Exit.cancelled_staging, try owner.clientExited(11, &queues));
        base.events = 0; // Keep unpublished dirty sectors, reset only the counter.
    }
    const generation = initial.generation();
    var cases: usize = 0;
    var event_count: usize = 0;
    for ([_]media.Background{ .none, .alternating, .all }) |background| for ([_]media.Order{ .ascending, .descending }) |order| {
        var clean = base;
        clean.background = background;
        clean.order = order;
        var store = initial;
        store.device = &clean;
        var owner = try api.Owner(Store).init(&store, 11);
        var queues = Queues{};
        _ = try owner.clientExited(11, &queues);
        _ = try owner.retirePrevious(&queues);
        try pinned(&store, reader, 0);
        event_count = clean.events;
        for (0..event_count) |event| for ([_]usize{ 0, 1, 31, 255, 511, 512 }) |prefix| {
            var broken = base;
            broken.background = background;
            broken.order = order;
            var interrupted = initial;
            interrupted.device = &broken;
            var stopped = try api.Owner(Store).init(&interrupted, 11);
            var mailboxes = Queues{};
            _ = try stopped.clientExited(11, &mailboxes);
            broken.cut = .{ .event = event, .prefix = prefix };
            try expectError(error.Io, stopped.retirePrevious(&mailboxes));
            try expect(stopped.recovery_required);
            const after = broken.events;
            try expectError(error.Faulted, stopped.retirePrevious(&mailboxes));
            try equal(after, broken.events);
            try expect(!stopped.rebind(12, &mailboxes));
            try interrupted.release(reader);
            broken.powerLoss();
            if (cancelled) {
                // F1 may persist cancelled orphan writes. Every other sector,
                // including all live/pinned data, must remain unchanged.
                for (16..base.dirty.len) |sector| if (!base.dirty[sector]) {
                    const offset = sector * media.sector_bytes;
                    try std.testing.expectEqualSlices(u8, base.stable[offset..][0..media.sector_bytes], broken.stable[offset..][0..media.sector_bytes]);
                };
            } else try std.testing.expectEqualSlices(u8, base.stable[2 * page ..], broken.stable[2 * page ..]);
            var recovered = Store{};
            try recovered.recover(&broken);
            try expect(recovered.generation() == generation or recovered.generation() == generation + 1);
            var byte: [1]u8 = undefined;
            _ = try recovered.read(1, 0, &byte);
            try equal(@as(u8, 'A'), byte[0]);
            cases += 1;
        };
    };
    try equal(@as(usize, if (cancelled) 42 else 18), event_count);
    try equal(@as(usize, if (cancelled) 1512 else 648), cases);
    std.debug.print("MAINTENANCE_CAMPAIGN cancelled_dirty={} events={d} crash_cases={d} acknowledged_cases=6\n", .{ cancelled, event_count, cases });
}
test "quiescent retirement fences every sector and sync cut without rewriting live data" {
    try retirementCampaign(false);
    try retirementCampaign(true);
}
