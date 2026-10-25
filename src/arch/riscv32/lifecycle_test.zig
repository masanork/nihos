//! End-to-end task lifecycle scenario using the reusable native runtime and
//! task-side ECALL wrappers. The bootstrap is the lowest-priority idle task.

const std = @import("std");
const context = @import("context.zig");
const runtime_module = @import("task_runtime.zig");
const calls = @import("task_calls.zig");
const control = @import("task_control");
const scheduler = @import("scheduler");
const tick_clock = @import("tick_clock");
const timer_group = @import("timer_group");

const Runtime = runtime_module.Runtime(3, 2);
const stack_bytes = 4096;
const period_us = 1000;
const sleep_ticks = 5;
const timeout_us = 100_000;

pub const Report = struct {
    sleep_started: u32,
    sleep_deadline: u32,
    sleep_resumed: u32,
    explicit_wakes: u32,
    exits: [2]i32,
    calls: u32,
    interrupts: u32,
    idle_runtime_ticks: u64,
    reaped: u32,
    old_generation: u16,
    replacement_generation: u16,
};

var runtime: Runtime = .{};
var stacks: [2][stack_bytes]u8 align(16) = undefined;
var bootstrap_handle = scheduler.TaskHandle{ .slot = 0, .generation = 0 };
var worker_handles: [2]scheduler.TaskHandle = @splat(.{ .slot = 0, .generation = 0 });
var device: ?timer_group.Timer = null;
var clock = tick_clock.TickClock.init(period_us).?;
var started_us: u64 = 0;
var launched = false;
var call_count: u32 = 0;
var interrupt_count: u32 = 0;
var finished = std.atomic.Value(bool).init(false);
var failed = std.atomic.Value(bool).init(false);
var stage = std.atomic.Value(u32).init(0);
var peer_progress = std.atomic.Value(u32).init(0);
var sleep_started = std.atomic.Value(u32).init(0);
var sleep_deadline = std.atomic.Value(u32).init(0);
var sleep_resumed = std.atomic.Value(u32).init(0);
var explicit_wakes = std.atomic.Value(u32).init(0);
var exited: [2]std.atomic.Value(u32) = @splat(.init(0));
var stack_addresses: [2]std.atomic.Value(u32) = @splat(.init(0));
var terminal_wake_rejected = std.atomic.Value(bool).init(false);

extern fn nih_platform_monotonic_us() callconv(.c) u64;

fn expired() bool {
    return nih_platform_monotonic_us() - started_us >= timeout_us;
}

fn fail(code: i32) noreturn {
    failed.store(true, .monotonic);
    calls.exit(code);
}

fn checkCanary(canary: *volatile [4]u32, expected: u32) void {
    for (0..4) |index| if (canary[index] != expected) fail(-100);
}

fn sleeper(_: u32) callconv(.c) i32 {
    var canary: [4]u32 = @splat(0x736c_6565);
    const checked: *volatile [4]u32 = &canary;
    stack_addresses[0].store(@intCast(@intFromPtr(&canary)), .monotonic);
    const me = calls.current() orelse fail(-101);
    if (control.encodeHandle(me) != control.encodeHandle(worker_handles[0])) fail(-102);
    const invalid: i32 = @bitCast(@as(u32, @truncate(calls.raw(0x4e49_ffff, 0))));
    if (invalid != calls.Status.invalid_call or calls.sleep(0) != calls.Status.invalid_argument)
        fail(-103);

    const before: u32 = @intCast(calls.nowTicks());
    sleep_started.store(before, .monotonic);
    sleep_deadline.store(before + sleep_ticks, .monotonic);
    stage.store(1, .monotonic);
    if (calls.sleep(sleep_ticks) != calls.Status.ok) fail(-104);
    const resumed: u32 = @intCast(calls.nowTicks());
    sleep_resumed.store(resumed, .monotonic);
    if (resumed < sleep_deadline.load(.monotonic) or peer_progress.load(.monotonic) == 0)
        fail(-105);
    checkCanary(checked, 0x736c_6565);

    stage.store(2, .monotonic);
    if (calls.block() != calls.Status.ok) fail(-106);
    checkCanary(checked, 0x736c_6565);
    stage.store(3, .monotonic);
    return 17; // The task trampoline must turn this return into EXIT(17).
}

fn waker(_: u32) callconv(.c) i32 {
    var canary: [4]u32 = @splat(0x7761_6b65);
    const checked: *volatile [4]u32 = &canary;
    stack_addresses[1].store(@intCast(@intFromPtr(&canary)), .monotonic);
    const me = calls.current() orelse fail(-110);
    if (control.encodeHandle(me) != control.encodeHandle(worker_handles[1])) fail(-111);
    if (calls.yieldNow() != calls.Status.ok) fail(-112);
    // Both workers now sleep together, so the captured bootstrap must run
    // until the next deadline instead of resuming an unavailable worker.
    const before_idle = calls.nowTicks();
    if (calls.sleep(2) != calls.Status.ok or calls.nowTicks() < before_idle + 2) fail(-118);
    var count: u32 = 0;
    while (stage.load(.monotonic) < 2 and exited[0].load(.monotonic) == 0) {
        count +%= 1;
        peer_progress.store(count, .monotonic);
        if (count & 255 == 0 and expired()) fail(-113);
    }
    if (stage.load(.monotonic) != 2) fail(-114);
    const target = control.Handle{
        .slot = worker_handles[0].slot,
        .generation = worker_handles[0].generation,
    };
    while (true) {
        const result = calls.wake(target);
        if (result == calls.Status.ok) break;
        // A timer may have preempted the sleeper immediately before BLOCK.
        if (result != calls.Status.invalid_state or expired()) fail(-115);
    }
    explicit_wakes.store(1, .monotonic);
    while (exited[0].load(.monotonic) == 0) if (expired()) fail(-116);
    if (calls.wake(target) != calls.Status.invalid_state) fail(-117);
    terminal_wake_rejected.store(true, .monotonic);
    checkCanary(checked, 0x7761_6b65);
    return 37;
}

pub fn prepare(timer: timer_group.Timer, stack_min: u32, stack_max: u32, gp: u32, tp: u32, trampoline: u32) bool {
    runtime = .{};
    device = timer;
    clock = tick_clock.TickClock.init(period_us).?;
    launched = false;
    call_count = 0;
    interrupt_count = 0;
    finished.store(false, .monotonic);
    failed.store(false, .monotonic);
    stage.store(0, .monotonic);
    peer_progress.store(0, .monotonic);
    sleep_started.store(0, .monotonic);
    sleep_deadline.store(0, .monotonic);
    sleep_resumed.store(0, .monotonic);
    explicit_wakes.store(0, .monotonic);
    terminal_wake_rejected.store(false, .monotonic);
    bootstrap_handle = runtime.add(1, .{ .stack_min = stack_min, .stack_max = stack_max }) orelse
        return false;
    _ = runtime.policy.schedule() orelse return false;
    const entries = [_]*const fn (u32) callconv(.c) i32{ &sleeper, &waker };
    for (&stacks, entries, 0..) |*stack, entry, index| {
        exited[index].store(0, .monotonic);
        stack_addresses[index].store(0, .monotonic);
        const bottom: u32 = @intCast(@intFromPtr(stack));
        const frame_address = context.initialTaskFrameAddress(bottom, stack_bytes) orelse return false;
        const frame: *context.IntegerContext = @ptrFromInt(frame_address);
        context.initialize(frame, .{
            .entry = @intCast(@intFromPtr(entry)),
            .argument = 0,
            .trampoline = trampoline,
            .global_pointer = gp,
            .thread_pointer = tp,
        });
        worker_handles[index] = runtime.add(0, .{
            .frame = frame,
            .stack_min = bottom,
            .stack_max = bottom + stack_bytes,
        }) orelse return false;
    }
    return timer.configureOneShot(period_us);
}

pub fn startMasked() bool {
    started_us = nih_platform_monotonic_us();
    (device orelse return false).start();
    return true;
}

pub fn run() bool {
    while (!finished.load(.monotonic)) {
        if (expired()) break;
        std.atomic.spinLoopHint();
    }
    (device orelse return false).stop();
    return finished.load(.monotonic) and !failed.load(.monotonic);
}

fn refreshClock() bool {
    const timer = device orelse return false;
    for (0..4) |_| {
        const now = timer.counter() orelse return false;
        const advance = clock.observe(now) orelse return false;
        if (!runtime.policy.elapse(advance.elapsed_ticks)) return false;
        if (!timer.armAt(advance.next_deadline)) return false;
        const after = timer.counter() orelse return false;
        if (after < advance.next_deadline) return true;
        _ = timer.clearPending();
    }
    return false;
}

fn checkedSelection(selected: context.TaskContext) ?context.TaskContext {
    const current = runtime.policy.current() orelse return null;
    for (worker_handles, 0..) |handle, index| {
        if (current.slot == handle.slot and exited[index].load(.monotonic) != 0) return null;
    }
    return selected;
}

pub fn onTimer(frame: *context.IntegerContext, state: context.ReturnState) ?context.TaskContext {
    if (!runtime.capture(frame, state)) return null;
    if (!(device orelse return null).clearPending() or !refreshClock()) return null;
    interrupt_count += 1;
    if (!launched) {
        for (worker_handles) |handle| runtime.images[handle.slot].?.state = state.integerOnly();
        launched = true;
    }
    return checkedSelection(runtime.select() orelse return null);
}

pub fn onCall(frame: *context.IntegerContext, state: context.ReturnState) ?context.TaskContext {
    if (!refreshClock()) return null;
    call_count += 1;
    const caller = runtime.policy.current() orelse return null;
    const number = control.Number.decode(frame.a7);
    const selected = runtime.call(frame, state) orelse return null;
    if (number == .sleep and caller.slot == worker_handles[0].slot) {
        const snapshot = runtime.policy.snapshot(caller) orelse return null;
        if (snapshot.state == .sleeping) {
            // Record the accepted kernel deadline, not a task-side time read
            // that could precede the syscall by a timer boundary.
            sleep_started.store(@intCast(runtime.policy.now()), .monotonic);
            sleep_deadline.store(@intCast(snapshot.wake_tick), .monotonic);
        }
    }
    for (worker_handles, 0..) |handle, index| {
        const snapshot = runtime.policy.snapshot(handle) orelse return null;
        if (snapshot.state == .exited) exited[index].store(1, .monotonic);
    }
    if (exited[0].load(.monotonic) != 0 and exited[1].load(.monotonic) != 0) {
        (device orelse return null).stop();
        finished.store(true, .monotonic);
        if ((runtime.policy.current() orelse return null).slot != bootstrap_handle.slot) return null;
    }
    return checkedSelection(selected);
}

pub fn report() ?Report {
    if (!finished.load(.monotonic) or failed.load(.monotonic) or
        explicit_wakes.load(.monotonic) != 1 or !terminal_wake_rejected.load(.monotonic)) return null;
    var result = Report{
        .sleep_started = sleep_started.load(.monotonic),
        .sleep_deadline = sleep_deadline.load(.monotonic),
        .sleep_resumed = sleep_resumed.load(.monotonic),
        .explicit_wakes = explicit_wakes.load(.monotonic),
        .exits = @splat(0),
        .calls = call_count,
        .interrupts = interrupt_count,
        .idle_runtime_ticks = (runtime.policy.snapshot(bootstrap_handle) orelse return null).runtime_ticks,
        .reaped = 0,
        .old_generation = worker_handles[0].generation,
        .replacement_generation = 0,
    };
    if (result.idle_runtime_ticks < 2 or result.sleep_resumed < result.sleep_deadline or
        result.sleep_deadline != result.sleep_started + sleep_ticks) return null;
    const replacement_image = runtime.images[worker_handles[0].slot] orelse return null;
    for (worker_handles, 0..) |handle, index| {
        const image = runtime.images[handle.slot] orelse return null;
        const address = stack_addresses[index].load(.monotonic);
        const snapshot = runtime.policy.snapshot(handle) orelse return null;
        if (snapshot.state != .exited or address < image.stack_min or address >= image.stack_max)
            return null;
        result.exits[index] = snapshot.exit_code;
        if (!runtime.reap(handle)) return null;
        result.reaped += 1;
    }
    if (result.exits[0] != 17 or result.exits[1] != 37) return null;
    // Reuse a reaped slot without executing it. The stale handle must not
    // affect the new ready task; its context storage belongs to this test.
    const replacement = runtime.add(0, replacement_image) orelse return null;
    if (replacement.slot != worker_handles[0].slot or
        replacement.generation == worker_handles[0].generation) return null;
    const stale = control.dispatch(&runtime.policy, @backingInt(control.Number.wake), control.encodeHandle(worker_handles[0]));
    if (stale.statusCode() != control.Status.not_found or
        runtime.policy.snapshot(replacement).?.state != .ready) return null;
    result.replacement_generation = replacement.generation;
    return result;
}
