const std = @import("std");
const buddy = @import("buddy_heap.zig");
const resources = @import("task_resources.zig");
const Key = resources.Key;
const Table = resources.Resources(buddy, 3, 2);

test "bounded extent group uses one ledger entry and rejects foreign or stale children" {
    const GroupTable = resources.ResourcesWithGroups(buddy, 3, 2, 1, 4);
    var memory: [16384]u8 align(64) = undefined;
    var heap = buddy.Heap.init(&memory, 0).?;
    var table = GroupTable{};
    const a = Key{ .slot = 0, .generation = 1 };
    const b = Key{ .slot = 1, .generation = 1 };
    try std.testing.expect(table.open(a) and table.open(b));
    const group = try table.openGroup(&heap, 0, a);
    @memset(group.allocation.bytes, 0xa5); // root payload is not authoritative metadata
    const raw = try table.alloc(&heap, 0, a, 32, 8);
    try std.testing.expectError(error.Full, table.alloc(&heap, 0, a, 32, 8));
    var children: [4]buddy.Allocation = undefined;
    for (&children, 0..) |*child, i| {
        child.* = try table.allocExtent(&heap, 0, a, group, (i + 1) * 64, 16);
        @memset(child.bytes, @intCast(i + 1));
    }
    const before = heap.free_bytes;
    try std.testing.expectEqual(@as(usize, 4), try table.extentCount(0, a, group));
    try std.testing.expectError(error.InvalidAllocation, table.extentFromPointer(0, a, group, 1));
    try std.testing.expectEqual(children[0].ticket, (try table.extentFromPointer(0, a, group, @intFromPtr(children[0].bytes.ptr))).ticket);
    try std.testing.expectError(error.Full, table.allocExtent(&heap, 0, a, group, 64, 16));
    try std.testing.expectError(error.GroupBusy, table.free(&heap, 0, a, group.allocation));
    try std.testing.expectError(error.WrongOwner, table.allocExtent(&heap, 1, a, group, 64, 16));
    try std.testing.expectError(error.Inactive, table.freeExtent(&heap, 0, b, group, children[0]));
    var forged = group;
    forged.token.ticket += 1;
    try std.testing.expectError(error.InvalidGroup, table.freeExtent(&heap, 0, a, forged, children[0]));
    var interior = children[0];
    interior.bytes = interior.bytes[1..];
    try std.testing.expectError(error.InvalidAllocation, table.freeExtent(&heap, 0, a, group, interior));
    try std.testing.expectError(error.InvalidAllocation, table.freeExtent(&heap, 0, a, group, raw));
    try std.testing.expectError(error.InvalidAllocation, table.free(&heap, 0, a, children[0]));
    try std.testing.expectEqual(before, heap.free_bytes);
    try table.freeExtent(&heap, 0, a, group, children[0]);
    const replacement = try table.allocExtent(&heap, 0, a, group, 64, 16);
    try std.testing.expectError(error.InvalidAllocation, table.freeExtent(&heap, 0, a, group, children[0]));
    try table.freeExtent(&heap, 0, a, group, replacement);
    for (children[1..], 1..) |child, i| {
        for (child.bytes) |byte| try std.testing.expectEqual(@as(u8, @intCast(i + 1)), byte);
        try table.freeExtent(&heap, 0, a, group, child);
    }
    try table.closeGroup(&heap, 0, a, group);
    try table.free(&heap, 0, a, raw);
    try std.testing.expectEqual(heap.payload.len, heap.free_bytes);
}

test "group registration and extent OOM roll back without leaking ledger slots" {
    const GroupTable = resources.ResourcesWithGroups(buddy, 2, 2, 1, 4);
    var memory: [8192]u8 align(64) = undefined;
    var heap = buddy.Heap.init(&memory, 0).?;
    var table = GroupTable{};
    const a = Key{ .slot = 0, .generation = 1 };
    const b = Key{ .slot = 1, .generation = 1 };
    try std.testing.expect(table.open(a) and table.open(b));
    const group = try table.openGroup(&heap, 0, a);
    const before = heap.free_bytes;
    try std.testing.expectError(error.Full, table.openGroup(&heap, 0, b));
    try std.testing.expectEqual(before, heap.free_bytes);
    try std.testing.expectEqual(@as(u32, 1), table.owned());
    try std.testing.expectError(error.OutOfMemory, table.allocExtent(&heap, 0, a, group, heap.payload.len - 32, 8));
    try std.testing.expectEqual(before, heap.free_bytes);
    try std.testing.expectEqual(@as(usize, 0), try table.extentCount(0, a, group));
    try table.closeGroup(&heap, 0, a, group);
    try std.testing.expectEqual(heap.payload.len, heap.free_bytes);
    const raw = try table.alloc(&heap, 0, b, 64, 8);
    try table.free(&heap, 0, b, raw);
}

test "closing group drains one child per call then root while peer task survives" {
    const GroupTable = resources.ResourcesWithGroups(buddy, 2, 2, 1, 4);
    var memory: [16384]u8 align(64) = undefined;
    var heap = buddy.Heap.init(&memory, 0).?;
    var table = GroupTable{};
    const a = Key{ .slot = 0, .generation = 1 };
    const next = Key{ .slot = 0, .generation = 2 };
    const b = Key{ .slot = 1, .generation = 1 };
    try std.testing.expect(table.open(a) and table.open(b));
    const peer = try table.alloc(&heap, 0, b, 256, 8);
    @memset(peer.bytes, 0x76);
    const group = try table.openGroup(&heap, 0, a);
    for (0..4) |_| _ = try table.allocExtent(&heap, 0, a, group, 128, 16);
    try std.testing.expect(table.close(a));
    try std.testing.expectError(error.Inactive, table.allocExtent(&heap, 0, a, group, 32, 8));
    for (0..4) |_| {
        const frees = heap.frees;
        try std.testing.expect(!try table.drainOne(&heap, 0, a));
        try std.testing.expectEqual(frees + 1, heap.frees);
        try std.testing.expect(!table.open(next));
        for (peer.bytes) |byte| try std.testing.expectEqual(@as(u8, 0x76), byte);
    }
    const frees = heap.frees;
    try std.testing.expect(try table.drainOne(&heap, 0, a));
    try std.testing.expectEqual(frees + 1, heap.frees);
    try std.testing.expect(table.open(next));
    try std.testing.expectError(error.Inactive, table.closeGroup(&heap, 0, next, group));
    try table.free(&heap, 0, b, peer);
    try std.testing.expectEqual(heap.payload.len, heap.free_bytes);
}

test "failed group drain retains ownership and prevents task reuse" {
    const GroupTable = resources.ResourcesWithGroups(buddy, 1, 2, 1, 4);
    var memory: [8192]u8 align(64) = undefined;
    var heap = buddy.Heap.init(&memory, 0).?;
    var table = GroupTable{};
    const key = Key{ .slot = 0, .generation = 1 };
    try std.testing.expect(table.open(key));
    const group = try table.openGroup(&heap, 0, key);
    _ = try table.allocExtent(&heap, 0, key, group, 128, 16);
    try std.testing.expect(table.close(key));
    memory[0] ^= 1;
    const live = heap.live;
    try std.testing.expectError(error.Corrupt, table.drainOne(&heap, 0, key));
    try std.testing.expectEqual(live, heap.live);
    try std.testing.expectEqual(@as(u32, 1), table.owned());
    try std.testing.expect(!table.cleaned(key) and !table.open(.{ .slot = 0, .generation = 2 }));
}

test "close defers frees and forbids allocation or slot reuse until drained" {
    var memory: [4096]u8 align(64) = undefined;
    var heap = buddy.Heap.init(&memory, 0).?;
    var table = Table{};
    const old = Key{ .slot = 1, .generation = 1 };
    const next = Key{ .slot = 1, .generation = 2 };
    try std.testing.expect(table.open(old));
    _ = try table.alloc(&heap, 0, old, 32, 8);
    _ = try table.alloc(&heap, 0, old, 64, 64);
    const before = heap.free_bytes;
    try std.testing.expect(table.close(old));
    try std.testing.expect(table.close(old));
    try std.testing.expectEqual(before, heap.free_bytes);
    try std.testing.expectEqual(@as(u32, 1), table.closed);
    try std.testing.expect(!table.open(next));
    try std.testing.expectError(error.Inactive, table.alloc(&heap, 0, old, 8, 8));
    try std.testing.expect(!try table.drainOne(&heap, 0, old));
    try std.testing.expect(!table.open(next));
    try std.testing.expect(try table.drainOne(&heap, 0, old));
    try std.testing.expectEqual(heap.payload.len, heap.free_bytes);
    try std.testing.expect(table.cleaned(old));
    try std.testing.expect(table.open(next));
    try std.testing.expect(!table.close(old));
    try std.testing.expect(!table.active(old));
    try std.testing.expectError(error.Inactive, table.alloc(&heap, 0, old, 8, 8));
}

test "full ledger and rejected ownership cannot consume or release heap capacity" {
    var memory: [4096]u8 align(64) = undefined;
    var heap = buddy.Heap.init(&memory, 0).?;
    var table = Table{};
    const a = Key{ .slot = 0, .generation = 1 };
    const b = Key{ .slot = 1, .generation = 1 };
    try std.testing.expect(table.open(a) and table.open(b));
    const first = try table.alloc(&heap, 0, a, 32, 8);
    const second = try table.alloc(&heap, 0, a, 32, 8);
    const before = heap.free_bytes;
    try std.testing.expectError(error.Full, table.alloc(&heap, 0, a, 32, 8));
    try std.testing.expectError(error.InvalidAllocation, table.free(&heap, 0, b, first));
    try std.testing.expectError(error.WrongOwner, table.free(&heap, 1, a, first));
    var malformed = first;
    malformed.bytes = first.bytes[1..];
    try std.testing.expectError(error.InvalidAllocation, table.free(&heap, 0, a, malformed));
    try std.testing.expectEqual(before, heap.free_bytes);
    try table.free(&heap, 0, a, first);
    try std.testing.expectError(error.InvalidAllocation, table.free(&heap, 0, a, first));
    try table.free(&heap, 0, a, second);
    try std.testing.expectEqual(@as(u32, 0), table.owned());
}

test "empty close drains without freeing an unrelated live task" {
    var memory: [4096]u8 align(64) = undefined;
    var heap = buddy.Heap.init(&memory, 0).?;
    var table = Table{};
    const a = Key{ .slot = 0, .generation = 1 };
    const b = Key{ .slot = 1, .generation = 1 };
    try std.testing.expect(table.open(a) and table.open(b));
    const allocation = try table.alloc(&heap, 0, b, 128, 8);
    @memset(allocation.bytes, 0x6a);
    const before = heap.free_bytes;
    try std.testing.expect(table.close(a));
    try std.testing.expect(try table.drainOne(&heap, 0, a));
    try std.testing.expectEqual(before, heap.free_bytes);
    for (allocation.bytes) |byte| try std.testing.expectEqual(@as(u8, 0x6a), byte);
    try table.free(&heap, 0, b, allocation);
}

test "failed cleanup retains allocation and blocks generation reuse" {
    var memory: [4096]u8 align(64) = undefined;
    var heap = buddy.Heap.init(&memory, 0).?;
    var table = Table{};
    const key = Key{ .slot = 1, .generation = 1 };
    try std.testing.expect(table.open(key));
    _ = try table.alloc(&heap, 0, key, 32, 8);
    try std.testing.expect(table.close(key));
    memory[0] ^= 1;
    try std.testing.expectError(error.Corrupt, table.drainOne(&heap, 0, key));
    try std.testing.expectEqual(@as(u32, 1), table.owned());
    try std.testing.expect(!table.cleaned(key));
    try std.testing.expect(!table.open(.{ .slot = 1, .generation = 2 }));
}

test "heap allocation failure cannot leave a phantom ledger entry" {
    var memory: [4096]u8 align(64) = undefined;
    var heap = buddy.Heap.init(&memory, 0).?;
    var table = Table{};
    const key = Key{ .slot = 0, .generation = 1 };
    try std.testing.expect(table.open(key));
    try std.testing.expectError(error.OutOfMemory, table.alloc(&heap, 0, key, heap.payload.len - 32, 8));
    try std.testing.expectEqual(@as(u32, 0), table.owned());
    try std.testing.expect(table.close(key));
    try std.testing.expect(try table.drainOne(&heap, 0, key));
    try std.testing.expectEqual(@as(u32, 0), table.reclaimed);
    try std.testing.expectEqual(heap.payload.len, heap.free_bytes);
}

test "termination cancels running sleeping and waiting state without resurrection" {
    const scheduler = @import("scheduler.zig");
    for (0..3) |mode| {
        var policy = scheduler.Scheduler(2, 2){};
        const task = policy.add(0).?;
        const idle = policy.add(1).?;
        _ = policy.schedule().?;
        if (mode == 1) try std.testing.expect(policy.sleep(task, 2));
        if (mode == 2) _ = policy.waitEvents(task, 1).?;
        try std.testing.expect(policy.terminate(task, -7));
        try std.testing.expect(policy.elapse(100));
        try std.testing.expect(policy.notify(task, 1) == null);
        try std.testing.expectEqual(idle, policy.schedule().?);
        const snapshot = policy.snapshot(task).?;
        try std.testing.expectEqual(scheduler.TaskState.exited, snapshot.state);
        try std.testing.expectEqual(@as(i32, -7), snapshot.exit_code);
        try std.testing.expectEqual(@as(u32, 0), snapshot.pending_events | snapshot.wait_mask);
        try std.testing.expectEqual(@as(u64, 0), snapshot.wake_tick);
    }
}

test "invalid exhausted and stale keys never open or drain another generation" {
    var memory: [4096]u8 align(64) = undefined;
    var heap = buddy.Heap.init(&memory, 0).?;
    var table = Table{};
    try std.testing.expect(!table.open(.{ .slot = 3, .generation = 1 }));
    try std.testing.expect(!table.open(.{ .slot = 0, .generation = 0 }));
    const last = Key{ .slot = 0, .generation = 65535 };
    try std.testing.expect(table.open(last));
    try std.testing.expect(table.close(last));
    try std.testing.expect(try table.drainOne(&heap, 0, last));
    try std.testing.expect(!table.open(.{ .slot = 0, .generation = 1 }));
    try std.testing.expectError(error.Inactive, table.drainOne(&heap, 0, .{ .slot = 0, .generation = 1 }));
}

test "termination of a blocked resource owner keeps completion until cleanup" {
    const scheduler = @import("scheduler.zig");
    var policy = scheduler.Scheduler(2, 2){};
    var memory: [4096]u8 align(64) = undefined;
    var heap = buddy.Heap.init(&memory, 0).?;
    var table = Table{};
    const task = policy.add(0).?;
    const idle = policy.add(1).?;
    const key = Key{ .slot = task.slot, .generation = task.generation };
    try std.testing.expect(table.open(key));
    _ = try table.alloc(&heap, 0, key, 128, 8);
    _ = policy.schedule().?;
    try std.testing.expect(policy.block(task));
    try std.testing.expectEqual(idle, policy.schedule().?);
    try std.testing.expect(policy.terminate(task, -99));
    try std.testing.expectEqual(@as(i32, -99), policy.snapshot(task).?.exit_code);
    try std.testing.expect(!policy.wake(task));
    try std.testing.expect(!policy.terminate(task, -99));
    try std.testing.expect(table.close(key));
    try std.testing.expect(try table.drainOne(&heap, 0, key));
    try std.testing.expect(policy.remove(task));
    const next = policy.add(0).?;
    try std.testing.expect(!policy.terminate(task, 1));
    try std.testing.expect(next.generation != task.generation);
}
