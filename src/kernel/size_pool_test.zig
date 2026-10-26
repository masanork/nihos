const std = @import("std");
const pool = @import("size_pool.zig");
const buddy = @import("buddy_heap.zig");
const resources = @import("task_resources.zig");
const Table = resources.Resources(buddy, 2, 2);
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const fails = std.testing.expectError;

test "size classes bound capacity and keep independent fixed quotas" {
    try expect(pool.requiredBytes(0) == null);
    try expect(pool.requiredBytes(65536) == null);
    try expect(pool.classFor(0) == null and pool.classFor(4097) == null);
    var memory: [pool.requiredBytes(2).?]u8 align(8) = undefined;
    try equal(@as(usize, 17008), memory.len);
    try expect(pool.View.from(&memory, 1, 1) == null);
    try expect(pool.View.from(&memory, 2, 0) == null);
    try expect(pool.View.from(memory[1..], 2, 1) == null);
    const view = pool.View.from(&memory, 2, 1).?;
    try view.initialize();
    try view.ready();
    var previous: usize = 0;
    for (pool.classes, 0..) |capacity, index| {
        const low = try view.alloc(previous + 1);
        const high = try view.alloc(capacity);
        try equal(@as(u32, @intCast(index)), low.class);
        try equal(capacity, try view.capacity(low));
        try equal(previous + 1, low.cell.bytes.len);
        try expect(@intFromPtr(low.cell.bytes.ptr) % 8 == 0);
        try expect(@intFromPtr(low.cell.bytes.ptr) + capacity <= @intFromPtr(high.cell.bytes.ptr));
        try fails(error.OutOfMemory, view.alloc(capacity));
        try view.free(low);
        try view.free(high);
        previous = capacity;
    }
    try fails(error.InvalidRequest, view.alloc(0));
    try fails(error.InvalidRequest, view.alloc(4097));
}

test "in-place resize renews exact length and stale operation tickets" {
    var memory: [pool.requiredBytes(1).?]u8 align(8) = undefined;
    const view = pool.View.from(&memory, 1, 9).?;
    try view.initialize();
    const old = try view.alloc(13);
    @memset(old.cell.bytes, 0x71);
    var forged = old;
    forged.cell.bytes = old.cell.bytes[0..12];
    try fails(error.InvalidAllocation, view.free(forged));
    forged = old;
    forged.class = 999;
    try fails(error.InvalidAllocation, view.capacity(forged));
    const next = (try view.beginResize(old, 15)).done.?;
    try equal(old.cell.bytes.ptr, next.cell.bytes.ptr);
    try expect(old.cell.ticket != next.cell.ticket);
    try fails(error.InvalidAllocation, view.free(old));
    try fails(error.InvalidAllocation, view.beginResize(old, 0));
    for (next.cell.bytes[0..13]) |byte| try equal(@as(u8, 0x71), byte);
    const shrunk = (try view.beginResize(next, 3)).done.?;
    try equal(@as(usize, 16), try view.capacity(shrunk));
    const same = (try view.beginResize(shrunk, 3)).done.?;
    try fails(error.InvalidAllocation, view.validate(shrunk));
    try expect((try view.beginResize(same, 0)).done == null);
    try fails(error.InvalidAllocation, view.free(same));
    try expect((try view.beginResize(null, 0)).done == null);
    const fresh = (try view.beginResize(null, 7)).done.?;
    try view.free(fresh);
}

test "moving resize retains source on OOM cancellation and rejected commit" {
    var memory: [pool.requiredBytes(1).?]u8 align(8) = undefined;
    const view = pool.View.from(&memory, 1, 7).?;
    try view.initialize();
    const old = try view.alloc(31);
    @memset(old.cell.bytes, 0x4a);
    const blocker = try view.alloc(4096);
    try fails(error.OutOfMemory, view.beginResize(old, 4096));
    try fails(error.InvalidRequest, view.beginResize(old, 4097));
    try view.validate(old);
    for (old.cell.bytes) |byte| try equal(@as(u8, 0x4a), byte);
    try view.free(blocker);
    const canceled = (try view.beginResize(old, 4096)).move;
    try view.cancel(canceled);
    try fails(error.InvalidAllocation, view.commit(canceled));
    try fails(error.InvalidAllocation, view.cancel(canceled));
    try view.validate(old);
    const plan = (try view.beginResize(old, 4096)).move;
    @memcpy(plan.next.cell.bytes[0..old.cell.bytes.len], old.cell.bytes);
    const next = try view.commit(plan);
    for (next.cell.bytes[0..31]) |byte| try equal(@as(u8, 0x4a), byte);
    try fails(error.InvalidAllocation, view.commit(plan));
    try fails(error.InvalidAllocation, view.free(old));
    var bad = plan;
    bad.old = next;
    try fails(error.InvalidAllocation, view.cancel(bad));
    try view.free(next);
}

test "task death during unpublished initialization or move reclaims one opaque parent" {
    for (0..2) |phase| {
        var memory: [65536]u8 align(64) = undefined;
        var heap = buddy.Heap.init(&memory, 0).?;
        var table = Table{};
        const key = resources.Key{ .slot = 0, .generation = 1 };
        try expect(table.open(key));
        const lease = try table.reserveObjects(&heap, 0, key, 2);
        try equal(@as(u32, 1), table.owned());
        try fails(error.NotReady, table.allocObject(0, key, lease, 13));
        const view = try table.prepareObjects(0, key, lease);
        try view.initialize();
        if (phase == 1) {
            try table.publishObjects(0, key, lease);
            const old = try table.allocObject(0, key, lease, 13);
            const plan = (try table.beginObjectResize(0, key, lease, old, 4096)).move;
            @memset(plan.next.cell.bytes, 0x9a);
        }
        try expect(table.close(key));
        try expect(try table.drainOne(&heap, 0, key));
        try equal(@as(u32, 1), table.reclaimed);
        try equal(heap.payload.len, heap.free_bytes);
        try fails(error.Inactive, table.allocObject(0, key, lease, 13));
    }
}

test "object leases validate task hart storage kind and reused parent epoch" {
    var memory: [65536]u8 align(64) = undefined;
    var heap = buddy.Heap.init(&memory, 0).?;
    var table = Table{};
    const key = resources.Key{ .slot = 0, .generation = 1 };
    const other = resources.Key{ .slot = 1, .generation = 1 };
    try expect(table.open(key) and table.open(other));
    const lease = try table.reserveObjects(&heap, 0, key, 1);
    try (try table.prepareObjects(0, key, lease)).initialize();
    try table.publishObjects(0, key, lease);
    try fails(error.InvalidAllocation, table.publishObjects(0, key, lease));
    const old = try table.allocObject(0, key, lease, 12);
    try fails(error.WrongOwner, table.freeObject(1, key, lease, old));
    try fails(error.Inactive, table.freeObject(0, other, lease, old));
    var fake = lease;
    fake.key = other;
    try fails(error.InvalidAllocation, table.freeObject(0, other, fake, old));
    const raw = try table.alloc(&heap, 0, key, 64, 8);
    try fails(error.InvalidAllocation, table.allocObject(0, key, .{ .key = key, .allocation = raw }, 8));
    try table.free(&heap, 0, key, raw);
    try table.closeObjects(&heap, 0, key, lease);
    const next = try table.reserveObjects(&heap, 0, key, 1);
    try equal(lease.allocation.bytes.ptr, next.allocation.bytes.ptr);
    try (try table.prepareObjects(0, key, next)).initialize();
    try table.publishObjects(0, key, next);
    _ = try table.allocObject(0, key, next, 12);
    try fails(error.InvalidAllocation, table.freeObject(0, key, next, old));
    try fails(error.InvalidAllocation, table.allocObject(0, key, lease, 8));
    try table.closeObjects(&heap, 0, key, next);
    try equal(heap.payload.len, heap.free_bytes);
}

test "canceling a move can release its destination despite a poisoned source" {
    var memory: [pool.requiredBytes(1).?]u8 align(8) = undefined;
    const view = pool.View.from(&memory, 1, 5).?;
    try view.initialize();
    const old = try view.alloc(7);
    const plan = (try view.beginResize(old, 4096)).move;
    memory[0] ^= 1; // Source-class serial no longer matches its header cookie.
    try fails(error.Corrupt, view.commit(plan));
    try view.cancel(plan);
    _ = try view.alloc(4096);
    try fails(error.Faulted, view.validate(old));
}

test "stale moving plans cannot affect a new task generation at the same address" {
    var memory: [65536]u8 align(64) = undefined;
    var heap = buddy.Heap.init(&memory, 0).?;
    var table = Table{};
    const key = resources.Key{ .slot = 0, .generation = 1 };
    const next_key = resources.Key{ .slot = 0, .generation = 2 };
    try expect(table.open(key));
    const lease = try table.reserveObjects(&heap, 0, key, 1);
    try (try table.prepareObjects(0, key, lease)).initialize();
    try table.publishObjects(0, key, lease);
    const old = try table.allocObject(0, key, lease, 7);
    const plan = (try table.beginObjectResize(0, key, lease, old, 4096)).move;
    // Generic cleanup must not read the now-poisoned source-class header.
    lease.allocation.bytes[0] ^= 1;
    try expect(table.close(key));
    try expect(try table.drainOne(&heap, 0, key));
    try expect(table.open(next_key));
    const next = try table.reserveObjects(&heap, 0, next_key, 1);
    try equal(lease.allocation.bytes.ptr, next.allocation.bytes.ptr);
    try (try table.prepareObjects(0, next_key, next)).initialize();
    try table.publishObjects(0, next_key, next);
    const live = try table.allocObject(0, next_key, next, 7);
    _ = try table.allocObject(0, next_key, next, 4096);
    try fails(error.Inactive, table.commitObjectResize(0, next_key, lease, plan));
    try fails(error.InvalidAllocation, table.commitObjectResize(0, next_key, next, plan));
    try fails(error.InvalidAllocation, table.cancelObjectResize(0, next_key, next, plan));
    try equal(@as(usize, 8), try table.objectCapacity(0, next_key, next, live));
    try table.closeObjects(&heap, 0, next_key, next);
    try equal(heap.payload.len, heap.free_bytes);
}
