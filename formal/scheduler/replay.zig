//! Replay a TLC-generated lasso against the real scheduler module.
const std = @import("std");
const scheduler = @import("scheduler");
const trace = @import("trace_data");

pub fn main() !void {
    var policy = scheduler.Scheduler(trace.task_count, 2){};
    const high = policy.add(0).?;
    var handles: [trace.task_count]scheduler.TaskHandle = undefined;
    handles[0] = high;
    for (handles[1..]) |*handle| handle.* = policy.add(1).?;
    if (!policy.block(high)) return error.SetupFailed;

    for (trace.steps, 0..) |step, index| {
        switch (step.action) {
            .init => if (index != 0) return error.UnexpectedInit,
            .schedule => {
                _ = policy.schedule() orelse return error.UnexpectedIdle;
            },
            .wake_high => if (!policy.wake(high)) return error.WakeFailed,
            .block_high => if (!policy.block(high)) return error.BlockFailed,
        }
        const actual_current = if (policy.current()) |handle| @as(usize, handle.slot) + 1 else 0;
        if (actual_current != step.current) {
            std.log.err("MODEL_MISMATCH step={d} action={s} expected_current={d} actual_current={d}", .{ index, @tagName(step.action), step.current, actual_current });
            return error.ModelMismatch;
        }
        for (handles, step.states, 0..) |handle, expected, slot| {
            const actual = policy.snapshot(handle).?.state;
            if (!std.mem.eql(u8, @tagName(actual), @tagName(expected))) {
                std.log.err("MODEL_MISMATCH step={d} slot={d} expected={s} actual={s}", .{ index, slot, @tagName(expected), @tagName(actual) });
                return error.ModelMismatch;
            }
        }
        if (trace.check_cursors) {
            // The legacy scalar projection permits replaying an unmodified
            // baseline snapshot, as well as the array-based candidate/mutant.
            const actual: [2]usize = if (@TypeOf(policy.last_selected) == usize)
                .{ policy.last_selected + 1, trace.task_count }
            else
                .{ policy.last_selected[0] + 1, policy.last_selected[1] + 1 };
            if (!std.mem.eql(usize, &step.cursor, &actual)) {
                std.log.err("MODEL_MISMATCH step={d} cursor expected={any} actual={any}", .{ index, step.cursor, actual });
                return error.ModelMismatch;
            }
        }
    }
    std.log.info("REPLAY_OK tasks={d} states={d} cursors={}", .{ trace.task_count, trace.steps.len, trace.check_cursors });
}
