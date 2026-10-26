const std = @import("std");
const buddy = @import("buddy_heap.zig");
const resources = @import("task_resources.zig");
const Key = resources.Key;
const Table = resources.Resources(buddy, 3, 2);

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
