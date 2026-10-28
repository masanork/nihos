const std = @import("std");
const api = @import("checkpoint_service.zig");
const media = @import("model_media.zig");
const dispatch = api.dispatch_gate;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const Backend = media.Media(64 * 4096);
const Device = struct {
    pub const capacity = Backend.capacity;
    backend: *Backend,
    callback: ?*const fn (*@This()) anyerror!void = null,
    context: ?*anyopaque = null,
    callback_failed: bool = false,
    pub fn read(self: *@This(), offset: u64, bytes: []u8) error{Io}!void {
        return self.backend.read(offset, bytes);
    }
    pub fn write(self: *@This(), offset: u64, bytes: []const u8) error{Io}!void {
        return self.backend.write(offset, bytes);
    }
    pub fn sync(self: *@This()) error{Io}!void {
        if (self.callback) |callback| {
            self.callback = null;
            callback(self) catch {
                self.callback_failed = true;
                return error.Io;
            };
        }
        return self.backend.sync();
    }
};
const Store = api.model.Store(Device, .{ .leaf_pages = 1, .index_pages = 8, .leaf_cache_pages = 1 });
const Owner = api.Owner(Store);
const Queues = api.Queues(@import("../kernel/spsc_ring.zig"));
const Gate = dispatch.Gate(Store, Owner, Queues);
fn seed(store: *Store, device: *Device) !void {
    var scratch = api.model.MapScratch{};
    try store.format(device);
    try store.begin();
    try store.put(1, "");
    try store.put(2, "");
    try store.commit();
    try store.begin();
    try store.resizeMapped(1, 4096, &scratch);
    try store.commit();
}
fn send(owner: *Owner, queues: *Queues, handle: api.Handle, operation: api.Operation, length: u64, byte: ?u8) !api.Response {
    var request = api.Request{ .epoch = owner.epoch, .sequence = owner.next_sequence, .handle = handle, .operation = @backingInt(operation), .offset = length };
    if (byte) |value| {
        request.offset = 0;
        request.length = 1;
        request.data[0] = value;
    }
    try expect(queues.requests.tryPush(request));
    while (true) switch (owner.step(queues, .{})) {
        .pending => {},
        .idle => return error.UnexpectedIdle,
        .completed => return queues.responses.tryPop() orelse error.NoReply,
    };
}
test "dispatch gate queues before recovery and maintenance and scrubs cancelled FIFO intents" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    try seed(&store, &device);
    var owner = try Owner.init(&store, 11);
    var queues = Queues{};
    var gate = try Gate.init(&owner, &queues, 101, 2);
    const first = try gate.submit(71, 1);
    const second = try gate.submit(72, 2);
    const before = backend.events;
    try expectError(error.NotReady, gate.take(12));
    try expectError(error.NotReady, gate.stepMaintenance());
    try expectError(error.Busy, gate.submit(73, 3));
    try equal(dispatch.Cancellation.unknown, gate.cancel(72, first));
    try equal(dispatch.Cancellation.unknown, gate.cancel(71, .{ .epoch = 100, .sequence = first.sequence }));
    try equal(dispatch.Cancellation.cancelled_waiting, gate.cancel(71, first));
    try equal(second.sequence, gate.waiting[0].ticket.sequence);
    try equal(@as(u64, 0), gate.waiting[1].actor);
    try equal(before, backend.events);
    _ = try owner.clientExited(11, &queues);
    try gate.recoveryComplete();
    try gate.requestMaintenance();
    try expectError(error.Busy, gate.take(12));
    _ = try gate.stepMaintenance();
    const active = (try gate.take(12)).?;
    try equal(second.sequence, active.ticket.sequence);
    try equal(@as(u64, 72), active.actor);
    try equal(@as(u64, 0), gate.waiting[0].actor);
    try equal(@as(u8, 0), gate.count);
    try expectError(error.InvalidTicket, gate.finish(71, active.ticket));
    try expectError(error.Busy, gate.finish(72, active.ticket));
    _ = try owner.clientExited(12, &queues);
    try equal(dispatch.Completion.clean, try gate.finish(72, active.ticket));
}
test "active cancellation keeps the lease until rollback and worker teardown finish" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    try seed(&store, &device);
    var owner = try Owner.init(&store, 11);
    var queues = Queues{};
    _ = try owner.clientExited(11, &queues);
    var gate = try Gate.init(&owner, &queues, 102, 2);
    try gate.recoveryComplete();
    const ticket = try gate.submit(71, 1);
    _ = try gate.take(12);
    const waiting = try gate.submit(72, 2);
    _ = try gate.submit(73, 3);
    try expectError(error.Busy, gate.submit(74, 4));
    const handle = try owner.grant(1, true);
    try equal(api.Status.ok, (try send(&owner, &queues, handle, .write, 0, 'X')).status);
    try gate.requestMaintenance();
    try equal(dispatch.Cancellation.requested_active, gate.cancel(71, ticket));
    try equal(dispatch.Cancellation.cancelled_waiting, gate.cancel(72, waiting));
    try expect(gate.cancellationRequested(71, ticket));
    try expect(!gate.cancellationRequested(72, ticket));
    const before = backend.events;
    try expectError(error.Busy, gate.stepMaintenance());
    try expectError(error.Busy, gate.finish(71, ticket));
    try equal(before, backend.events);
    // This fixture models a clean SQL abort: its journal was never published.
    try equal(api.Exit.cancelled_staging, try owner.clientExited(12, &queues));
    try expectError(error.Busy, gate.stepMaintenance()); // lease still active
    try equal(dispatch.Completion.clean, try gate.finish(71, ticket));
    _ = try gate.stepMaintenance();
    var byte: [1]u8 = undefined;
    _ = try store.read(1, 0, &byte);
    try equal(@as(u8, 0), byte[0]);
    try expect(!gate.cancellationRequested(71, ticket));
    const next = (try gate.take(13)).?;
    try equal(@as(u64, 73), next.actor);
    _ = try owner.clientExited(13, &queues);
    _ = try gate.finish(next.actor, next.ticket);
}
test "late cancellation is only a request and cannot undo an acknowledged commit" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    try seed(&store, &device);
    var owner = try Owner.init(&store, 11);
    var queues = Queues{};
    _ = try owner.clientExited(11, &queues);
    var gate = try Gate.init(&owner, &queues, 108, 2);
    try gate.recoveryComplete();
    const ticket = try gate.submit(71, 1);
    _ = try gate.take(12);
    const handle = try owner.grant(1, true);
    _ = try send(&owner, &queues, handle, .write, 0, 'A');
    _ = try send(&owner, &queues, handle, .sync, 0, null);
    _ = try owner.clientExited(12, &queues);
    try equal(dispatch.Cancellation.requested_active, gate.cancel(71, ticket));
    try equal(dispatch.Completion.clean, try gate.finish(71, ticket));
    backend.powerLoss();
    var mounted = Store{};
    try mounted.recover(&device);
    var byte: [1]u8 = undefined;
    _ = try mounted.read(1, 0, &byte);
    try equal(@as(u8, 'A'), byte[0]);
}
const Pump = struct { gate: *Gate, cancelled: ?dispatch.Ticket = null, kept: ?dispatch.Ticket = null };
fn pumpIntents(device: *Device) !void {
    const pump: *Pump = @ptrCast(@alignCast(device.context.?));
    try equal(dispatch.Mode.maintenance, pump.gate.mode);
    const first = try pump.gate.submit(71, 11);
    const second = try pump.gate.submit(72, 22);
    try expectError(error.Busy, pump.gate.submit(73, 33));
    try expectError(error.Busy, pump.gate.take(12));
    try equal(dispatch.Cancellation.cancelled_waiting, pump.gate.cancel(71, first));
    pump.cancelled = first;
    pump.kept = second;
}
test "maintenance callback can queue and cancel intents but cannot start a transaction" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    try seed(&store, &device);
    var owner = try Owner.init(&store, 11);
    var queues = Queues{};
    _ = try owner.clientExited(11, &queues);
    var gate = try Gate.init(&owner, &queues, 103, 2);
    try gate.recoveryComplete();
    var pump = Pump{ .gate = &gate };
    device.context = &pump;
    device.callback = pumpIntents;
    try gate.requestMaintenance();
    _ = try gate.stepMaintenance();
    try expect(!device.callback_failed);
    try equal(dispatch.Mode.ready, gate.mode);
    const active = (try gate.take(12)).?;
    try equal(pump.kept.?.sequence, active.ticket.sequence);
    try equal(dispatch.Cancellation.unknown, gate.cancel(71, pump.cancelled.?));
    _ = try owner.clientExited(12, &queues);
    _ = try gate.finish(active.actor, active.ticket);
}
test "published journal forces recovery before queued dispatch or maintenance" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    try seed(&store, &device);
    var owner = try Owner.init(&store, 11);
    var queues = Queues{};
    _ = try owner.clientExited(11, &queues);
    var gate = try Gate.init(&owner, &queues, 104, 2);
    try gate.recoveryComplete();
    const ticket = try gate.submit(71, 1);
    _ = try gate.take(12);
    const journal = try owner.grant(2, true);
    _ = try send(&owner, &queues, journal, .truncate, 4096, null);
    _ = try send(&owner, &queues, journal, .write, 0, 0xd9);
    _ = try send(&owner, &queues, journal, .sync, 0, null);
    _ = try owner.clientExited(12, &queues);
    try equal(dispatch.Completion.recovery_required, try gate.finish(71, ticket));
    try equal(dispatch.Mode.recovering, gate.mode);
    _ = try gate.submit(72, 2);
    try gate.requestMaintenance();
    const before = backend.events;
    try expectError(error.NotReady, gate.take(13));
    try expectError(error.NotReady, gate.stepMaintenance());
    try expectError(error.NotReady, gate.recoveryComplete());
    try equal(before, backend.events);
    // Trusted recovery driver; no queued application intent is dispatched.
    try expect(owner.rebind(13, &queues));
    const recovery = try owner.grant(2, true);
    _ = try send(&owner, &queues, recovery, .truncate, 0, null);
    _ = try send(&owner, &queues, recovery, .sync, 0, null);
    _ = try owner.clientExited(13, &queues);
    try gate.recoveryComplete();
    _ = try gate.stepMaintenance();
    try equal(@as(u64, 72), (try gate.take(14)).?.actor);
}
test "faulted gate cannot be reopened by clearing a device error and tickets never wrap" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    try seed(&store, &device);
    var owner = try Owner.init(&store, 11);
    var queues = Queues{};
    _ = try owner.clientExited(11, &queues);
    var gate = try Gate.init(&owner, &queues, 105, 2);
    gate.next_sequence = std.math.maxInt(u64);
    try expectError(error.GenerationExhausted, gate.submit(71, 1));
    try equal(@as(u8, 0), gate.count);
    gate.next_sequence = 1;
    const ticket = try gate.submit(71, 1);
    // Force a cold metadata read during the initial recovery barrier.
    store.dropMetadataCache();
    backend.read_error = true;
    try expectError(error.Io, gate.recoveryComplete());
    backend.read_error = false;
    try equal(dispatch.Mode.faulted, gate.mode);
    const before = backend.events;
    try expectError(error.Faulted, gate.recoveryComplete());
    try expectError(error.Faulted, gate.take(12));
    try expectError(error.Faulted, gate.stepMaintenance());
    try expectError(error.Faulted, gate.submit(72, 2));
    try equal(before, backend.events);
    try equal(dispatch.Cancellation.cancelled_waiting, gate.cancel(71, ticket));
}
test "restart begins behind recovery barrier and an old epoch cannot cancel new work" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    try seed(&store, &device);
    var owner = try Owner.init(&store, 11);
    var queues = Queues{};
    _ = try owner.clientExited(11, &queues);
    var old = try Gate.init(&owner, &queues, 106, 2);
    const stale = try old.submit(71, 1);
    var fresh = try Gate.init(&owner, &queues, 107, 2);
    const ticket = try fresh.submit(71, 2);
    try equal(dispatch.Cancellation.unknown, fresh.cancel(71, stale));
    try expectError(error.NotReady, fresh.take(12));
    try fresh.recoveryComplete();
    try equal(ticket.sequence, (try fresh.take(12)).?.ticket.sequence);
}
test "gate maintenance cuts fence all intents and restart never skips recovery" {
    var base = Backend{};
    var first = Device{ .backend = &base };
    var initial = Store{};
    try seed(&initial, &first);
    base.powerLoss();
    var cases: usize = 0;
    for ([_]media.Background{ .none, .alternating, .all }) |background| for ([_]media.Order{ .ascending, .descending }) |order| {
        for (0..18) |event| for ([_]usize{ 0, 1, 31, 255, 511, 512 }) |prefix| {
            var broken = base;
            broken.background = background;
            broken.order = order;
            var device = Device{ .backend = &broken };
            var store = Store{};
            try store.recover(&device);
            var owner = try Owner.init(&store, 11);
            var queues = Queues{};
            _ = try owner.clientExited(11, &queues);
            var gate = try Gate.init(&owner, &queues, 1000, 2);
            try gate.recoveryComplete();
            const old_ticket = try gate.submit(71, 1);
            try gate.requestMaintenance();
            broken.cut = .{ .event = event, .prefix = prefix };
            try expectError(error.Io, gate.stepMaintenance());
            try equal(dispatch.Mode.faulted, gate.mode);
            const after = broken.events;
            try expectError(error.Faulted, gate.take(12));
            try expectError(error.Faulted, gate.stepMaintenance());
            try expectError(error.Faulted, gate.recoveryComplete());
            try equal(after, broken.events);
            broken.powerLoss();
            var mounted = Store{};
            try mounted.recover(&device);
            var restarted_owner = try Owner.init(&mounted, 21);
            var restarted_queues = Queues{};
            _ = try restarted_owner.clientExited(21, &restarted_queues);
            var fresh = try Gate.init(&restarted_owner, &restarted_queues, 2000 + cases, 2);
            _ = try fresh.submit(71, 1); // caller retries; old volatile queue is gone
            try equal(dispatch.Cancellation.unknown, fresh.cancel(71, old_ticket));
            try expectError(error.NotReady, fresh.take(22));
            try fresh.recoveryComplete();
            const active = (try fresh.take(22)).?;
            try equal(@as(u64, 71), active.actor);
            cases += 1;
        };
    };
    try equal(@as(usize, 648), cases);
    std.debug.print("GATE_MAINTENANCE_CAMPAIGN crash_cases={d} dispatched_before_recovery=0\n", .{cases});
}
