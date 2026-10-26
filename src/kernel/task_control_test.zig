const std = @import("std");
const control = @import("task_control.zig");
const Number = control.Number;
const Status = control.Status;
const Handle = control.Handle;
const encodeHandle = control.encodeHandle;
const decodeHandle = control.decodeHandle;
const dispatch = control.dispatch;

test "native call handles round trip and reject invalid encodings" {
    const handle = Handle{ .slot = 12, .generation = 42 };
    try std.testing.expectEqual(handle, decodeHandle(encodeHandle(handle)).?);
    try std.testing.expect(decodeHandle(12) == null);
    try std.testing.expect(decodeHandle(0xffff_ffff) == null);
    try std.testing.expect(Number.decode(0x4e49_ffff) == null);
    const highest = Handle{ .slot = 65534, .generation = 65535 };
    try std.testing.expectEqual(highest, decodeHandle(encodeHandle(highest)).?);
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), control.Reply.status(Status.invalid_argument).high);
}

test "sleep and block suspend the caller until deadline or explicit wake" {
    const scheduler = @import("scheduler.zig");
    var policy = scheduler.Scheduler(2, 2){};
    const task = policy.add(0).?;
    const idle = policy.add(1).?;
    try std.testing.expectEqual(task, policy.schedule().?);
    const sleeping = dispatch(&policy, @backingInt(Number.sleep), 5);
    try std.testing.expect(sleeping.reschedule);
    try std.testing.expectEqual(idle, policy.schedule().?);
    try std.testing.expect(policy.elapse(4));
    try std.testing.expectEqual(idle, policy.schedule().?);
    try std.testing.expect(policy.elapse(1));
    try std.testing.expectEqual(task, policy.schedule().?);
    try std.testing.expect(dispatch(&policy, @backingInt(Number.block), 0).reschedule);
    try std.testing.expectEqual(idle, policy.schedule().?);
    try std.testing.expect(dispatch(&policy, @backingInt(Number.wake), encodeHandle(task)).reschedule);
    try std.testing.expectEqual(task, policy.schedule().?);
}

test "exit remains terminal until reaped and stale handles cannot wake replacements" {
    const scheduler = @import("scheduler.zig");
    var policy = scheduler.Scheduler(2, 2){};
    const task = policy.add(0).?;
    const idle = policy.add(1).?;
    _ = policy.schedule().?;
    try std.testing.expect(dispatch(&policy, @backingInt(Number.exit), 17).reschedule);
    try std.testing.expectEqual(@as(i32, 17), policy.snapshot(task).?.exit_code);
    try std.testing.expectEqual(idle, policy.schedule().?);
    const dead = dispatch(&policy, @backingInt(Number.wake), encodeHandle(task));
    try std.testing.expectEqual(Status.invalid_state, dead.statusCode());
    try std.testing.expect(policy.remove(task));
    const replacement = policy.add(0).?;
    try std.testing.expectEqual(task.slot, replacement.slot);
    try std.testing.expect(task.generation != replacement.generation);
    const stale = dispatch(&policy, @backingInt(Number.wake), encodeHandle(task));
    try std.testing.expectEqual(Status.not_found, stale.statusCode());
    try std.testing.expectEqual(scheduler.TaskState.ready, policy.snapshot(replacement).?.state);
}

test "rejected calls retain caller state and tick replies retain all 64 bits" {
    const scheduler = @import("scheduler.zig");
    var policy = scheduler.Scheduler(1, 1){};
    const task = policy.add(0).?;
    _ = policy.schedule().?;
    try std.testing.expectEqual(Status.invalid_call, dispatch(&policy, 0x4e49_ffff, 0).statusCode());
    try std.testing.expectEqual(Status.invalid_argument, dispatch(&policy, @backingInt(Number.sleep), 0).statusCode());
    try std.testing.expectEqual(task, policy.current().?);
    try std.testing.expect(policy.elapse(0x1_0000_0007));
    const now = dispatch(&policy, @backingInt(Number.ticks), 0);
    try std.testing.expectEqual(@as(u32, 7), now.low);
    try std.testing.expectEqual(@as(u32, 1), now.high);
}

test "event calls preserve bit 31 and reject payloads on scalar-only calls" {
    const scheduler = @import("scheduler.zig");
    var policy = scheduler.Scheduler(2, 2){};
    const task = policy.add(0).?;
    _ = policy.add(1).?;
    _ = policy.schedule().?;
    const bad = control.dispatchWithPayload(&policy, @backingInt(Number.sleep), 5, 1);
    try std.testing.expectEqual(Status.invalid_argument, bad.statusCode());
    try std.testing.expectEqual(task, policy.current().?);
    const posted = control.dispatchWithPayload(&policy, @backingInt(Number.notify), encodeHandle(task), 0x8000_0000);
    try std.testing.expectEqual(Status.ok, posted.statusCode());
    try std.testing.expect(!posted.reschedule);
    const received = dispatch(&policy, @backingInt(Number.wait_events), 0x8000_0000);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), received.low);
    try std.testing.expectEqual(@as(u32, 0), received.high);
    try std.testing.expect(!received.reschedule);
    try std.testing.expectEqual(Status.invalid_argument, dispatch(&policy, @backingInt(Number.wait_events), 0).statusCode());
    try std.testing.expectEqual(Status.invalid_argument, dispatch(&policy, @backingInt(Number.notify), encodeHandle(task)).statusCode());
}

test "an owner without a timer rejects sleep without suspending its caller" {
    const scheduler = @import("scheduler.zig");
    var policy = scheduler.Scheduler(2, 2){};
    const task = policy.add(0).?;
    _ = policy.add(1).?;
    _ = policy.schedule().?;
    const rejected = control.dispatchWithOptions(&policy, @backingInt(Number.sleep), 5, 0, .{ .sleep_enabled = false });
    try std.testing.expectEqual(Status.not_supported, rejected.statusCode());
    try std.testing.expect(!rejected.reschedule);
    try std.testing.expectEqual(task, policy.current().?);
    try std.testing.expectEqual(scheduler.TaskState.running, policy.snapshot(task).?.state);
    try std.testing.expectEqual(@as(u64, 0), policy.now());
}

test "event-waiting client can be terminated without consuming pending IPC" {
    const scheduler = @import("scheduler.zig");
    var policy = scheduler.Scheduler(2, 2){};
    const client = policy.add(0).?;
    const bootstrap = policy.add(1).?;
    try std.testing.expectEqual(client, policy.schedule().?);
    const waiting = dispatch(&policy, @backingInt(Number.wait_events), 1);
    try std.testing.expect(waiting.reschedule);
    try std.testing.expectEqual(scheduler.TaskState.waiting, policy.snapshot(client).?.state);
    try std.testing.expectEqual(bootstrap, policy.schedule().?);
    try std.testing.expect(policy.terminate(client, -98));
    try std.testing.expectEqual(@as(i32, -98), policy.snapshot(client).?.exit_code);
    try std.testing.expectEqual(@as(?bool, null), policy.notify(client, 1));
    try std.testing.expectEqual(bootstrap, policy.schedule().?);
    try std.testing.expect(policy.remove(client));
    const replacement = policy.add(0).?;
    try std.testing.expect(client.generation != replacement.generation);
    try std.testing.expectEqual(@as(?bool, null), policy.notify(client, 1));
}
