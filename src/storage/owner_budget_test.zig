//! Trusted, serialized host owner integration; not a native RPC implementation.
const std = @import("std");
const service = @import("checkpoint_service.zig");
const model = @import("checkpoint_model.zig");
const media = @import("model_media.zig");
const ring = @import("../kernel/spsc_ring.zig");
const Device = media.Media(64 * model.page_bytes);
const Store = model.Store(Device, .{ .leaf_pages = 1, .index_pages = 8, .leaf_cache_pages = 1 });
const Owner = service.Owner(Store);
const Queues = service.Queues(ring);
const budget = model.WriteBudget{ .payload_writes = 4, .index_writes = 2, .index_peak = 2, .payload_margin = 2, .index_margin = 1 };
fn seed(store: *Store, dev: *Device) !void {
    var scratch = model.MapScratch{};
    try store.format(dev);
    try store.begin();
    try store.put(1, "");
    try store.commit();
    try store.begin();
    try store.resizeMapped(1, model.page_bytes * 2, &scratch);
    try store.commit();
    try store.collectPayload();
}
fn request(owner: *Owner, handle: service.Handle, op: service.Operation) service.Request {
    return .{ .epoch = owner.epoch, .sequence = owner.next_sequence, .handle = handle, .operation = @backingInt(op) };
}
fn run(owner: *Owner, queues: *Queues, req: service.Request, pop: bool) !?service.Response {
    try std.testing.expect(queues.requests.tryPush(req));
    for (0..10000) |_| switch (owner.step(queues, .{ .leaf_visits = 1, .bitmap_pages = 1 })) {
        .idle => return error.UnexpectedIdle,
        .pending => {},
        .completed => return if (pop) queues.responses.tryPop() orelse error.NoReply else null,
    };
    return error.TooManySteps;
}
fn write(owner: *Owner, queues: *Queues, handle: service.Handle, b: u8) !service.Response {
    var req = request(owner, handle, .write);
    req.length = 1;
    req.data[0] = b;
    return (try run(owner, queues, req, true)).?;
}
fn read(store: *Store) !u8 {
    var b: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try store.read(1, 0, &b));
    return b[0];
}

test "owner budget admission and release require the correct live client and drained queues" {
    var dev = Device{};
    var store = Store{};
    try seed(&store, &dev);
    var owner = try Owner.init(&store, 17);
    var queues = Queues{};
    const handle = try owner.grant(1, true);
    try std.testing.expectError(error.InvalidArgument, owner.beginBudgeted(18, &queues, budget));
    owner.next_sequence = 0;
    try std.testing.expectError(error.InvalidArgument, owner.beginBudgeted(17, &queues, budget));
    owner.next_sequence = 1;
    try std.testing.expect(queues.requests.tryPush(request(&owner, handle, .stat)));
    try std.testing.expectError(error.Busy, owner.beginBudgeted(17, &queues, budget));
    _ = queues.requests.tryPop();
    try std.testing.expect(queues.responses.tryPush(.{}));
    try std.testing.expectError(error.Busy, owner.beginBudgeted(17, &queues, budget));
    _ = queues.responses.tryPop();
    try owner.beginBudgeted(17, &queues, budget);
    try std.testing.expectError(error.Busy, Owner.init(&store, 99));
    try std.testing.expectError(error.Busy, owner.releaseBudget(17, &queues));
    const first = try write(&owner, &queues, handle, 'A');
    try std.testing.expectEqual(service.Status.ok, first.status);
    try std.testing.expectEqual(service.Visibility.staged, first.visibility);
    _ = try run(&owner, &queues, request(&owner, handle, .sync), false);
    try std.testing.expectError(error.Busy, owner.releaseBudget(17, &queues));
    const reply = queues.responses.tryPop().?;
    try std.testing.expectEqual(service.Status.ok, reply.status);
    try std.testing.expectEqual(service.Visibility.committed, reply.visibility);
    try std.testing.expectEqual(@as(u8, 'A'), try read(&store));
    try std.testing.expectError(error.InvalidArgument, owner.releaseBudget(18, &queues));
    try owner.releaseBudget(17, &queues);
    try std.testing.expectEqual(service.Status.ok, (try write(&owner, &queues, handle, 'B')).status);
}

test "client exit rolls back staging but fences an unreleased published budget" {
    var dev = Device{};
    var store = Store{};
    try seed(&store, &dev);
    var owner = try Owner.init(&store, 17);
    var queues = Queues{};
    var handle = try owner.grant(1, true);
    try owner.beginBudgeted(17, &queues, budget);
    try std.testing.expectEqual(service.Status.ok, (try write(&owner, &queues, handle, 'A')).status);
    try std.testing.expectEqual(service.Exit.cancelled_staging, try owner.clientExited(17, &queues));
    try std.testing.expectEqual(@as(u8, 0), try read(&store));
    try std.testing.expect(owner.rebind(18, &queues));
    handle = try owner.grant(1, true);
    try owner.beginBudgeted(18, &queues, budget);
    try std.testing.expectEqual(service.Status.ok, (try write(&owner, &queues, handle, 'B')).status);
    _ = try run(&owner, &queues, request(&owner, handle, .sync), false);
    try std.testing.expectEqual(service.Exit.recovery_required, try owner.clientExited(18, &queues));
    try std.testing.expect(!owner.rebind(19, &queues));
    try std.testing.expectError(error.Faulted, owner.retirePrevious(&queues));
    try std.testing.expectError(error.Busy, Owner.init(&store, 19));
    dev.powerLoss();
    var recovered = Store{};
    try recovered.recover(&dev);
    try std.testing.expectEqual(@as(u8, 'B'), try read(&recovered));
    _ = try Owner.init(&recovered, 19);
}

test "owner fences budget exhaustion before any commit" {
    var dev = Device{};
    var store = Store{};
    try seed(&store, &dev);
    var owner = try Owner.init(&store, 17);
    var queues = Queues{};
    const handle = try owner.grant(1, true);
    try owner.beginBudgeted(17, &queues, .{ .payload_writes = 1, .index_writes = 1, .index_peak = 1, .payload_margin = 2, .index_margin = 1 });
    const result = try write(&owner, &queues, handle, 'X');
    try std.testing.expectEqual(service.Status.recovery_required, result.status);
    try std.testing.expectEqual(service.Visibility.unknown, result.visibility);
    try std.testing.expectEqual(service.Exit.recovery_required, try owner.clientExited(17, &queues));
    try std.testing.expect(!owner.rebind(18, &queues));
    dev.powerLoss();
    var recovered = Store{};
    try recovered.recover(&dev);
    try std.testing.expectEqual(@as(u8, 0), try read(&recovered));
}

test "owner holds the recovery fence across every modeled publication cut" {
    var baseline = Device{};
    var initial = Store{};
    try seed(&initial, &baseline);
    baseline.powerLoss();
    var clean = baseline;
    var good_store = Store{};
    try good_store.recover(&clean);
    var good_owner = try Owner.init(&good_store, 17);
    var good_queues = Queues{};
    const good_handle = try good_owner.grant(1, true);
    try good_owner.beginBudgeted(17, &good_queues, budget);
    try std.testing.expectEqual(service.Status.ok, (try write(&good_owner, &good_queues, good_handle, 'Q')).status);
    try std.testing.expectEqual(service.Status.ok, (try run(&good_owner, &good_queues, request(&good_owner, good_handle, .sync), true)).?.status);
    try good_owner.releaseBudget(17, &good_queues);
    const events = clean.events;
    var cases: usize = 0;
    for ([_]media.Background{ .none, .all }) |background| {
        for (0..events) |event| {
            var broken = baseline;
            broken.background = background;
            var store = Store{};
            try store.recover(&broken);
            var owner = try Owner.init(&store, 17);
            var queues = Queues{};
            const handle = try owner.grant(1, true);
            try owner.beginBudgeted(17, &queues, budget);
            broken.cut = .{ .event = event, .prefix = 31 };
            const write_result = try write(&owner, &queues, handle, 'Q');
            if (write_result.status == .ok) {
                const sync_result = (try run(&owner, &queues, request(&owner, handle, .sync), true)).?;
                try std.testing.expectEqual(service.Status.publication_unknown, sync_result.status);
                try std.testing.expectEqual(service.Visibility.unknown, sync_result.visibility);
            } else {
                try std.testing.expectEqual(service.Status.recovery_required, write_result.status);
                try std.testing.expectEqual(service.Visibility.unknown, write_result.visibility);
            }
            try std.testing.expectEqual(service.Exit.recovery_required, try owner.clientExited(17, &queues));
            try std.testing.expect(!owner.rebind(18, &queues));
            broken.powerLoss();
            var recovered = Store{};
            try recovered.recover(&broken);
            const result = try read(&recovered);
            try std.testing.expect(result == 0 or result == 'Q');
            try recovered.verify(1);
            _ = try Owner.init(&recovered, 18);
            cases += 1;
        }
    }
    std.debug.print("OWNER_BUDGET_CUTS events={d} cases={d}\n", .{ events, cases });
}

test "admission read failure immediately fences the owner" {
    var dev = Device{};
    var store = Store{};
    try seed(&store, &dev);
    var owner = try Owner.init(&store, 17);
    var queues = Queues{};
    dev.read_error = true;
    try std.testing.expectError(error.Io, owner.beginBudgeted(17, &queues, budget));
    try std.testing.expect(owner.recovery_required);
    try std.testing.expectEqual(service.Exit.recovery_required, try owner.clientExited(17, &queues));
    try std.testing.expect(!owner.rebind(18, &queues));
}

test "post-commit free-space read failure fences release and rebind" {
    var dev = Device{};
    var store = Store{};
    try seed(&store, &dev);
    var owner = try Owner.init(&store, 17);
    var queues = Queues{};
    const handle = try owner.grant(1, true);
    try owner.beginBudgeted(17, &queues, budget);
    try std.testing.expectEqual(service.Status.ok, (try write(&owner, &queues, handle, 'R')).status);
    try std.testing.expectEqual(service.Status.ok, (try run(&owner, &queues, request(&owner, handle, .sync), true)).?.status);
    store.dropMetadataCache();
    dev.read_error = true;
    try std.testing.expectError(error.Io, owner.releaseBudget(17, &queues));
    try std.testing.expect(owner.recovery_required);
    try std.testing.expect(store.budget != null);
    try std.testing.expectEqual(service.Exit.recovery_required, try owner.clientExited(17, &queues));
    try std.testing.expect(!owner.rebind(18, &queues));
}

test "owner cancels poisoned staging after allocation denial" {
    var dev = Device{};
    var store = Store{};
    try seed(&store, &dev);
    var owner = try Owner.init(&store, 17);
    var queues = Queues{};
    const handle = try owner.grant(1, true);
    try owner.beginBudgeted(17, &queues, budget);
    try std.testing.expectEqual(service.Status.ok, (try write(&owner, &queues, handle, 'A')).status);
    owner.payload_headroom = std.math.maxInt(u64);
    const denied = try write(&owner, &queues, handle, 'B');
    try std.testing.expectEqual(service.Status.no_space, denied.status);
    try std.testing.expect(store.budget_poisoned);
    const cancelled = (try run(&owner, &queues, request(&owner, handle, .cancel), true)).?;
    try std.testing.expectEqual(service.Status.ok, cancelled.status);
    try std.testing.expectEqual(service.Visibility.committed, cancelled.visibility);
    try std.testing.expect(store.budget == null);
    try std.testing.expectEqual(@as(u8, 0), try read(&store));
}
