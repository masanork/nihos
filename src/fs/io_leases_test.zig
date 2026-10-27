const std = @import("std");
const api = @import("io_leases.zig");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;
const mount = api.Reference{ .slot = 0, .generation = 1 };
const file = api.Reference{ .slot = 1, .generation = 1 };
const fence = api.Fence{ .device_idle = true, .descriptors_released = true, .cache_handed_back = true };

test "queued cancellation returns a lease without ever issuing DMA" {
    var leases = api.IoLeases(2){};
    try expectError(error.InvalidArgument, leases.retain(1, mount, file, 0));
    const request = try leases.retain(1, mount, file, 100);
    try expectError(error.Busy, leases.retain(1, mount, file, 100));
    try expectError(error.PermissionDenied, leases.cancel(2, request));
    try leases.cancel(1, request);
    try expectError(error.InvalidState, leases.start(request));
    try expect(!leases.deviceBusy());
    try expectError(error.PermissionDenied, leases.take(2, request));
    const completion = try leases.take(1, request);
    try equal(api.Outcome.cancelled, completion.outcome);
    try equal(@as(u64, 100), completion.buffer_lease);
    try expectError(error.StaleHandle, leases.take(1, request));
    try expect(!leases.holdsMount(mount));
}

test "active cancellation cannot release memory before all device fences" {
    var leases = api.IoLeases(2){};
    const request = try leases.retain(1, mount, file, 100);
    try leases.start(request);
    try leases.cancel(1, request);
    try expect(try leases.stopRequired(request));
    const incomplete = [_]api.Fence{
        .{},
        .{ .device_idle = true, .descriptors_released = true },
        .{ .device_idle = true, .cache_handed_back = true },
        .{ .descriptors_released = true, .cache_handed_back = true },
    };
    for (incomplete) |value| {
        try expectError(error.Busy, leases.finish(request, true, value));
        try expectError(error.Busy, leases.take(1, request));
        try expectError(error.Busy, leases.discard(request));
        try expect(leases.holdsFile(file));
    }
    try leases.finish(request, true, fence);
    try expect(!leases.deviceBusy());
    try expect(leases.holdsFile(file)); // Completion still owns the buffer.
    try equal(api.Outcome.cancelled, (try leases.take(1, request)).outcome);
    try expect(!leases.holdsFile(file));
}

test "removal retires queued work but active work waits for quiescence" {
    var leases = api.IoLeases(3){};
    const active = try leases.retain(1, mount, file, 100);
    const queued = try leases.retain(1, mount, file, 101);
    const unrelated_mount = api.Reference{ .slot = 1, .generation = 1 };
    const unrelated = try leases.retain(2, unrelated_mount, .{ .slot = 2, .generation = 1 }, 102);
    try leases.start(active);
    try expectError(error.Busy, leases.start(unrelated));
    leases.removeMount(mount);
    try equal(api.Outcome.removed, (try leases.take(1, queued)).outcome);
    try expectError(error.Busy, leases.discard(active));
    try leases.finish(active, false, fence);
    try equal(api.Outcome.removed, (try leases.discard(active)).outcome);
    try leases.start(unrelated);
    try leases.finish(unrelated, true, fence);
    try equal(api.Outcome.completed, (try leases.take(2, unrelated)).outcome);
}

test "late completions cannot release a reused request slot" {
    var leases = api.IoLeases(1){};
    const old = try leases.retain(1, mount, file, 100);
    try leases.start(old);
    try leases.finish(old, false, fence);
    try expectError(error.InvalidState, leases.finish(old, true, fence));
    try equal(api.Outcome.failed, (try leases.take(1, old)).outcome);
    const fresh = try leases.retain(2, .{ .slot = 0, .generation = 2 }, .{ .slot = 1, .generation = 2 }, 200);
    try equal(old.slot, fresh.slot);
    try expect(old.generation != fresh.generation);
    try leases.start(fresh);
    try expectError(error.StaleHandle, leases.finish(old, true, fence));
    try expectError(error.StaleHandle, leases.cancel(1, old));
    try expectError(error.Busy, leases.take(2, fresh));
    try leases.finish(fresh, true, fence);
    try equal(@as(u64, 200), (try leases.take(2, fresh)).buffer_lease);
}

test "request table exhaustion and generation retirement never overwrite leases" {
    var leases = api.IoLeases(1){};
    leases.slots[0].generation = std.math.maxInt(u64);
    const last = try leases.retain(1, mount, file, 100);
    try expectError(error.NoHandles, leases.retain(1, mount, file, 101));
    try leases.cancel(1, last);
    _ = try leases.take(1, last);
    try expectError(error.NoHandles, leases.retain(1, mount, file, 102));
    try expectError(error.StaleHandle, leases.mountOf(last));
}

test "cancel removal and finish order has one terminal outcome and one release" {
    const Event = enum { cancel, remove, finish };
    const orders = [_][3]Event{
        .{ .cancel, .remove, .finish }, .{ .remove, .cancel, .finish },
        .{ .cancel, .finish, .remove }, .{ .remove, .finish, .cancel },
        .{ .finish, .cancel, .remove }, .{ .finish, .remove, .cancel },
    };
    const expected = [_]api.Outcome{ .removed, .removed, .cancelled, .removed, .completed, .completed };
    for (orders, expected) |order, outcome| {
        var leases = api.IoLeases(1){};
        const request = try leases.retain(1, mount, file, 100);
        try leases.start(request);
        for (order) |event| {
            switch (event) {
                .cancel => try leases.cancel(1, request),
                .remove => leases.removeMount(mount),
                .finish => try leases.finish(request, true, fence),
            }
            try expect(leases.holdsFile(file));
        }
        try equal(outcome, (try leases.take(1, request)).outcome);
        try expectError(error.StaleHandle, leases.take(1, request));
    }
}
