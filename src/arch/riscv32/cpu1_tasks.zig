//! A separate owner-local runtime on CPU1. Interrupt tails only deliver
//! events and select frames; the service callback runs on a native task stack.
const std = @import("std");
const context = @import("context.zig");
const Runtime = @import("task_runtime.zig").Runtime(3, 2);
const calls = @import("task_calls.zig");
const control = @import("task_control");
const scheduler = @import("scheduler");

pub const request_bit: u32 = 1;
const observer_bit: u32 = 2;
const acknowledgement_bit: u32 = 4;
const stop_bit: u32 = 0x8000_0000;
const stack_bytes = 4096;
pub const Hooks = struct { work: *const fn () bool };
pub const Report = struct {
    syscalls: u32,
    selections: u32,
    switches: u32,
    ipi_task_captures: u32,
    observer_rounds: u32,
    delivered: u32,
    rejected: u32,
    reaped: u32,
    replacement_generation: u16,
};

var runtime: Runtime = .{};
var stacks: [2][stack_bytes]u8 align(16) = undefined;
var bootstrap = scheduler.TaskHandle{ .slot = 0, .generation = 0 };
var handles: [2]scheduler.TaskHandle = @splat(.{ .slot = 0, .generation = 0 });
var hooks: ?Hooks = null;
var launched = false;
var finished = std.atomic.Value(bool).init(false);
var failed = std.atomic.Value(bool).init(false);
var addresses: [2]std.atomic.Value(u32) = @splat(.init(0));
var exited: [2]bool = @splat(false);
var calls_count: u32 = 0;
var selections: u32 = 0;
var switches: u32 = 0;
var last_slot: u16 = 0;
var ipi_task_captures: u32 = 0;
var observer_rounds = std.atomic.Value(u32).init(0);
var delivered: u32 = 0;
var rejected: u32 = 0;
var final_report: ?Report = null;

extern fn nih_platform_cpu_id() callconv(.c) u32;

fn fail(code: i32) noreturn {
    failed.store(true, .release);
    calls.exit(code);
}

fn wait(mask: u32) u32 {
    return switch (calls.waitEvents(mask)) {
        .received => |bits| bits,
        .failed => fail(-180),
    };
}

fn check(canary: *volatile [4]u32, expected: u32) void {
    for (0..4) |index| if (canary[index] != expected) fail(-181);
}

fn service(_: u32) callconv(.c) i32 {
    var canary: [4]u32 = @splat(0x6331_7376);
    const checked: *volatile [4]u32 = &canary;
    addresses[0].store(@intCast(@intFromPtr(&canary)), .monotonic);
    const me = calls.current() orelse fail(-182);
    if (nih_platform_cpu_id() != 1 or control.encodeHandle(me) != control.encodeHandle(handles[0])) fail(-183);
    if (calls.sleep(1) != calls.Status.not_supported) fail(-184);
    while (true) {
        if (wait(request_bit | stop_bit) & stop_bit != 0) break;
        const peer = calls.Handle{ .slot = handles[1].slot, .generation = handles[1].generation };
        if (calls.notify(peer, observer_bit) != calls.Status.ok) fail(-185);
        if (wait(acknowledgement_bit | stop_bit) & stop_bit != 0) break;
        if (!(hooks orelse fail(-186)).work()) fail(-187);
        check(checked, 0x6331_7376);
        if (calls.yieldNow() != calls.Status.ok) fail(-188);
    }
    check(checked, 0x6331_7376);
    return 83;
}

fn observer(_: u32) callconv(.c) i32 {
    var canary: [4]u32 = @splat(0x6331_6f62);
    const checked: *volatile [4]u32 = &canary;
    addresses[1].store(@intCast(@intFromPtr(&canary)), .monotonic);
    const me = calls.current() orelse fail(-189);
    if (nih_platform_cpu_id() != 1 or control.encodeHandle(me) != control.encodeHandle(handles[1])) fail(-190);
    while (true) {
        if (wait(observer_bit | stop_bit) & stop_bit != 0) break;
        _ = observer_rounds.fetchAdd(1, .monotonic);
        const peer = calls.Handle{ .slot = handles[0].slot, .generation = handles[0].generation };
        if (calls.notify(peer, acknowledgement_bit) != calls.Status.ok) fail(-191);
        check(checked, 0x6331_6f62);
    }
    check(checked, 0x6331_6f62);
    return 89;
}

/// Called on CPU1, before installing its native vector or publishing ready.
pub fn prepare(minimum: u32, maximum: u32, gp: u32, tp: u32, trampoline: u32, callbacks: Hooks) bool {
    runtime = .{ .call_options = .{ .sleep_enabled = false } };
    hooks = callbacks;
    launched = false;
    finished.store(false, .monotonic);
    failed.store(false, .monotonic);
    calls_count = 0;
    selections = 0;
    switches = 0;
    ipi_task_captures = 0;
    observer_rounds.store(0, .monotonic);
    delivered = 0;
    rejected = 0;
    exited = @splat(false);
    final_report = null;
    bootstrap = runtime.add(1, .{ .stack_min = minimum, .stack_max = maximum }) orelse return false;
    last_slot = bootstrap.slot;
    _ = runtime.policy.schedule() orelse return false;
    const entries = [_]*const fn (u32) callconv(.c) i32{ &service, &observer };
    for (&stacks, entries, 0..) |*stack, entry, index| {
        addresses[index].store(0, .monotonic);
        const bottom: u32 = @intCast(@intFromPtr(stack));
        const address = context.initialTaskFrameAddress(bottom, stack_bytes) orelse return false;
        const frame: *context.IntegerContext = @ptrFromInt(address);
        context.initialize(frame, .{
            .entry = @intCast(@intFromPtr(entry)),
            .argument = 0,
            .trampoline = trampoline,
            .global_pointer = gp,
            .thread_pointer = tp,
        });
        handles[index] = runtime.add(0, .{ .frame = frame, .stack_min = bottom, .stack_max = bottom + stack_bytes }) orelse return false;
    }
    return true;
}

pub fn serviceHandle() calls.Handle {
    return .{ .slot = handles[0].slot, .generation = handles[0].generation };
}

pub fn containsServiceAddress(address: usize) bool {
    const image = runtime.images[handles[0].slot] orelse return false;
    return address >= image.stack_min and address < image.stack_max;
}

pub fn exitFlag() *const std.atomic.Value(bool) {
    return &finished;
}

fn selected(value: context.TaskContext) ?context.TaskContext {
    const current = runtime.policy.current() orelse return null;
    for (handles, 0..) |handle, index| {
        if (current.slot == handle.slot and exited[index]) return null;
    }
    selections += 1;
    if (current.slot != last_slot) switches += 1;
    last_slot = current.slot;
    return value;
}

pub fn onIpi(frame: *context.IntegerContext, state: context.ReturnState, inbox: anytype, doorbell: anytype, stopping: bool) ?context.TaskContext {
    if (!runtime.capture(frame, state)) return null;
    if ((runtime.policy.current() orelse return null).slot != bootstrap.slot) ipi_task_captures += 1;
    if (!launched) {
        for (handles) |handle| runtime.images[handle.slot].?.state = state.integerOnly();
        launched = true;
    }
    const drained = inbox.drain(&runtime.policy, 4, doorbell);
    delivered += drained.delivered;
    rejected += drained.rejected;
    if (stopping) for (handles) |handle| {
        _ = runtime.policy.notify(handle, stop_bit);
    };
    return selected(runtime.select() orelse return null);
}

pub fn onCall(frame: *context.IntegerContext, state: context.ReturnState) ?context.TaskContext {
    calls_count += 1;
    const selection = runtime.call(frame, state) orelse return null;
    for (handles, 0..) |handle, index| {
        exited[index] = (runtime.policy.snapshot(handle) orelse return null).state == .exited;
    }
    if (exited[0] and exited[1]) {
        if ((runtime.policy.current() orelse return null).slot != bootstrap.slot) return null;
        finished.store(true, .release);
    }
    return selected(selection);
}

/// On CPU1 after its native vector has returned to IDF; no native task can
/// still own these stacks. CPU0 may read the result only after joining.
pub fn finalize() bool {
    if (!finished.load(.acquire) or failed.load(.acquire)) return false;
    const replacement_image = runtime.images[handles[0].slot] orelse return false;
    const expected = [_]i32{ 83, 89 };
    var reaped: u32 = 0;
    for (handles, expected, 0..) |handle, code, index| {
        const snapshot = runtime.policy.snapshot(handle) orelse return false;
        const image = runtime.images[handle.slot] orelse return false;
        const address = addresses[index].load(.monotonic);
        if (snapshot.state != .exited or snapshot.exit_code != code or address < image.stack_min or address >= image.stack_max) return false;
        if (!runtime.reap(handle)) return false;
        reaped += 1;
    }
    const replacement = runtime.add(0, replacement_image) orelse return false;
    const stale = control.dispatchWithPayload(&runtime.policy, @backingInt(control.Number.notify), control.encodeHandle(handles[0]), 1);
    if (replacement.slot != handles[0].slot or replacement.generation == handles[0].generation or
        stale.statusCode() != control.Status.not_found or runtime.policy.snapshot(replacement).?.pending_events != 0) return false;
    final_report = .{
        .syscalls = calls_count,
        .selections = selections,
        .switches = switches,
        .ipi_task_captures = ipi_task_captures,
        .observer_rounds = observer_rounds.load(.monotonic),
        .delivered = delivered,
        .rejected = rejected,
        .reaped = reaped,
        .replacement_generation = replacement.generation,
    };
    return true;
}

pub fn report() ?Report {
    return final_report;
}
