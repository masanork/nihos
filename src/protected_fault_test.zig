//! Host proof that a contained fault keeps its ledger until the bytes are
//! back, and only then reaps the scheduler slot for a new generation.

const std = @import("std");
const scheduler = @import("scheduler");
const runtime_module = @import("arch/riscv32/task_runtime.zig");
const pmp = @import("arch/riscv32/pmp.zig");
const buddy = @import("kernel/buddy_heap.zig");
const resources = @import("kernel/task_resources.zig");

const user_region = runtime_module.context.Protection{
    .code_lo = 0x3000,
    .code_hi = 0x3100,
    .data_lo = 0x2000,
    .data_hi = 0x2800,
};

test "a protected fault drains its ledger before the slot is reused" {
    const Key = resources.Key;
    var memory: [4096]u8 align(64) = undefined;
    var heap = buddy.Heap.init(&memory, 0).?;
    var ledger = resources.Resources(buddy, 4, 2){};
    const Runtime2 = runtime_module.Runtime(2, 2);
    var runtime = Runtime2{};
    const kernel = runtime.add(1, .{
        .stack_min = 0x1000,
        .stack_max = 0x1800,
        .state = .{ .mstatus = 0x1880, .mcause = 0 },
    }).?;
    const user = runtime.add(0, .{
        .stack_min = user_region.data_lo,
        .stack_max = user_region.data_hi,
        .state = .{ .mstatus = pmp.user_mstatus, .mcause = 0 },
        .protection = user_region,
    }).?;
    const user_key = Key{ .slot = user.slot, .generation = user.generation };
    const next_key = Key{ .slot = user.slot, .generation = user.generation + 1 };
    try std.testing.expect(ledger.open(user_key));
    const allocation = try ledger.alloc(&heap, 0, user_key, 64, 8);
    try std.testing.expect(allocation.bytes.len >= 64);
    try std.testing.expect(heap.free_bytes < heap.payload.len);
    try std.testing.expectEqual(user, runtime.policy.schedule().?);
    try std.testing.expect(!runtime.faultCloseable(user));
    try std.testing.expect(!runtime.faultCloseable(kernel));
    const fault = runtime.containFault();
    try std.testing.expectEqual(user, fault.exited.?);
    try std.testing.expect(runtime.faultCloseable(user));
    try std.testing.expect(!runtime.faultCloseable(kernel));
    try std.testing.expectEqual(scheduler.TaskState.running, runtime.policy.snapshot(kernel).?.state);
    try std.testing.expect(runtime.add(0, .{
        .stack_min = user_region.data_lo,
        .stack_max = user_region.data_hi,
        .state = .{ .mstatus = pmp.user_mstatus, .mcause = 0 },
        .protection = user_region,
    }) == null);

    var completed: u64 = 0;
    try std.testing.expectEqual(Runtime2.Reclaim.waiting, runtime.reclaimIfClean(user, false, &completed));
    try std.testing.expect(runtime.policy.snapshot(user) != null);
    try std.testing.expect(!ledger.cleaned(user_key));
    try std.testing.expect(!ledger.open(next_key));
    try std.testing.expect(ledger.close(user_key));
    try std.testing.expect(ledger.close(user_key));
    try std.testing.expect(!ledger.open(next_key));
    while (!ledger.cleaned(user_key)) _ = try ledger.drainOne(&heap, 0, user_key);
    try std.testing.expectEqual(heap.payload.len, heap.free_bytes);
    const ticks = runtime.policy.snapshot(user).?.runtime_ticks;
    try std.testing.expectEqual(Runtime2.Reclaim.reaped, runtime.reclaimIfClean(user, true, &completed));
    try std.testing.expectEqual(ticks, completed);
    try std.testing.expect(runtime.policy.snapshot(user) == null);
    try std.testing.expect(!runtime.faultCloseable(user));
    try std.testing.expectEqual(scheduler.TaskState.running, runtime.policy.snapshot(kernel).?.state);

    const replacement = runtime.add(0, .{
        .stack_min = user_region.data_lo,
        .stack_max = user_region.data_hi,
        .state = .{ .mstatus = pmp.user_mstatus, .mcause = 0 },
        .protection = user_region,
    }).?;
    try std.testing.expectEqual(user.slot, replacement.slot);
    try std.testing.expect(replacement.generation != user.generation);
    const replacement_key = Key{ .slot = replacement.slot, .generation = replacement.generation };
    try std.testing.expect(ledger.open(replacement_key));
    try std.testing.expectEqual(@as(u32, 1), ledger.reuses);
    _ = try ledger.alloc(&heap, 0, replacement_key, 32, 8);
    try std.testing.expectError(error.Inactive, ledger.alloc(&heap, 0, user_key, 32, 8));
    try std.testing.expectEqual(scheduler.TaskState.running, runtime.policy.snapshot(kernel).?.state);
}
