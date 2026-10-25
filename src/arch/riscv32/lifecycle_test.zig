//! End-to-end lifecycle, event, and IPC scenarios using the native runtime and
//! task-side ECALL wrappers. The bootstrap is the lowest-priority idle task.

const std = @import("std");
const context = @import("context.zig");
const runtime_module = @import("task_runtime.zig");
const calls = @import("task_calls.zig");
const control = @import("task_control");
const scheduler = @import("scheduler");
const tick_clock = @import("tick_clock");
const timer_group = @import("timer_group");
const ipc = @import("ipc_scenario.zig");
const remote = @import("remote_scenario.zig");
const duplex = @import("duplex_scenario.zig");
const Doorbell = @import("software_ipi").Doorbell;

const Runtime = runtime_module.Runtime(3, 2);
const stack_bytes = 4096;
const period_us = 1000;
const sleep_ticks = 5;
const timeout_us = 100_000;

pub const Mode = enum { lifecycle, events, ipc, remote, duplex, cpu1_tasks, cpu1_preemption, cpu1_floating, smp_floating };

pub const FloatingReport = struct {
    saves: u32,
    restores: u32,
    ipi_interrupts: u32,
    timer_captures: [2]u32,
    ipi_captures: [2]u32,
    calls: [2]u32,
    initial_fs: u32,
    final_fs: u32,
    boundary_restored: bool,
    elapsed_ticks: u64,
    runtime_ticks: u64,
};

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
    immediate_events: u32,
    blocked_events: u32,
    delivered_events: u32,
    ipc: ?ipc.Report = null,
    remote: ?remote.Report = null,
    duplex: ?duplex.Report = null,
    floating: ?FloatingReport = null,
};

var runtime: Runtime = .{};
var mode: Mode = .lifecycle;
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
var immediate_events: u32 = 0;
var blocked_events: u32 = 0;
var delivered_events = std.atomic.Value(u32).init(0);
var posted_events = std.atomic.Value(bool).init(false);
var bootstrap_floating: context.FloatingContext align(16) = std.mem.zeroes(context.FloatingContext);
var floating_states: [2]context.FloatingContext align(16) = @splat(std.mem.zeroes(context.FloatingContext));
var boundary_before: context.FloatingContext align(16) = std.mem.zeroes(context.FloatingContext);
var boundary_after: context.FloatingContext align(16) = std.mem.zeroes(context.FloatingContext);
var floating_timer_captures: [2]u32 = @splat(0);
var floating_ipi_captures: [2]u32 = @splat(0);
var floating_call_captures: [2]u32 = @splat(0);
var floating_ipi_interrupts: u32 = 0;
var floating_initial_fs: u32 = 0;
var floating_final_fs: u32 = 0;
var floating_boundary_restored = false;

extern var nih_riscv_current_floating_states: [2]u32;
extern var nih_riscv_selected_floating_states: [2]u32;
extern var nih_riscv_floating_saves: [2]u32;
extern var nih_riscv_floating_restores: [2]u32;
extern fn nih_riscv_fpu_snapshot(out: *context.FloatingContext) callconv(.c) void;

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

fn receive(mask: u32, expected: u32) void {
    switch (calls.waitEvents(mask)) {
        .received => |bits| if (bits != expected) fail(-120),
        .failed => fail(-121),
    }
}

fn eventReceiver(_: u32) callconv(.c) i32 {
    var canary: [4]u32 = @splat(0x6576_7263);
    const checked: *volatile [4]u32 = &canary;
    stack_addresses[0].store(@intCast(@intFromPtr(&canary)), .monotonic);
    const me = calls.current() orelse fail(-122);
    if (control.encodeHandle(me) != control.encodeHandle(worker_handles[0])) fail(-123);
    switch (calls.waitEvents(0)) {
        .failed => |code| if (code != calls.Status.invalid_argument) fail(-124),
        .received => fail(-125),
    }
    if (calls.notify(me, 0) != calls.Status.invalid_argument) fail(-126);
    const before = calls.nowTicks();
    if (calls.sleep(2) != calls.Status.ok) fail(-127);
    sleep_resumed.store(@intCast(calls.nowTicks()), .monotonic);
    if (sleep_resumed.load(.monotonic) < before + 2) fail(-128);
    // Synchronize the duplicate posts even if a timer boundary splits them.
    while (!posted_events.load(.monotonic)) if (expired()) fail(-129);
    receive(1, 1);
    receive(0x8000_0002, 0x8000_0002);
    // The duplicate bit must have coalesced; this wait must actually block.
    receive(1, 1);
    delivered_events.store(1, .monotonic);
    receive(4, 4); // A nonmatching notification was retained while waiting.
    checkCanary(checked, 0x6576_7263);
    return 41;
}

fn eventSender(_: u32) callconv(.c) i32 {
    var canary: [4]u32 = @splat(0x6576_736e);
    const checked: *volatile [4]u32 = &canary;
    stack_addresses[1].store(@intCast(@intFromPtr(&canary)), .monotonic);
    const me = calls.current() orelse fail(-130);
    if (control.encodeHandle(me) != control.encodeHandle(worker_handles[1])) fail(-131);
    const target = control.Handle{
        .slot = worker_handles[0].slot,
        .generation = worker_handles[0].generation,
    };
    if (calls.notify(target, 0x8000_0003) != calls.Status.ok or
        calls.notify(target, 1) != calls.Status.ok) fail(-132);
    posted_events.store(true, .monotonic);
    // Observe the serialized policy through a task call rather than sharing
    // its non-atomic bookkeeping with running task code.
    while (stage.load(.monotonic) == 0) {
        if (expired() or calls.sleep(1) != calls.Status.ok) fail(-133);
    }
    if (calls.notify(target, 4) != calls.Status.ok or calls.sleep(1) != calls.Status.ok)
        fail(-134);
    if (delivered_events.load(.monotonic) != 0) fail(-135);
    if (calls.notify(target, 1) != calls.Status.ok) fail(-136);
    while (exited[0].load(.monotonic) == 0) if (expired()) fail(-137);
    if (calls.notify(target, 1) != calls.Status.invalid_state) fail(-138);
    terminal_wake_rejected.store(true, .monotonic);
    checkCanary(checked, 0x6576_736e);
    return 43;
}

pub fn prepare(timer: timer_group.Timer, stack_min: u32, stack_max: u32, gp: u32, tp: u32, trampoline: u32, selected_mode: Mode, ipi: ?Doorbell) bool {
    runtime = .{};
    mode = selected_mode;
    device = timer;
    clock = tick_clock.TickClock.init(period_us).?;
    launched = false;
    call_count = 0;
    interrupt_count = 0;
    floating_timer_captures = @splat(0);
    floating_ipi_captures = @splat(0);
    floating_call_captures = @splat(0);
    floating_ipi_interrupts = 0;
    floating_initial_fs = 0;
    floating_final_fs = 0;
    floating_boundary_restored = false;
    finished.store(false, .monotonic);
    failed.store(false, .monotonic);
    stage.store(0, .monotonic);
    peer_progress.store(0, .monotonic);
    sleep_started.store(0, .monotonic);
    sleep_deadline.store(0, .monotonic);
    sleep_resumed.store(0, .monotonic);
    explicit_wakes.store(0, .monotonic);
    terminal_wake_rejected.store(false, .monotonic);
    immediate_events = 0;
    blocked_events = 0;
    delivered_events.store(0, .monotonic);
    posted_events.store(false, .monotonic);
    bootstrap_handle = runtime.add(1, .{ .stack_min = stack_min, .stack_max = stack_max }) orelse
        return false;
    _ = runtime.policy.schedule() orelse return false;
    const entries = switch (mode) {
        .lifecycle => [_]*const fn (u32) callconv(.c) i32{ &sleeper, &waker },
        .events => [_]*const fn (u32) callconv(.c) i32{ &eventReceiver, &eventSender },
        .ipc => [_]*const fn (u32) callconv(.c) i32{ &ipc.client, &ipc.service },
        .remote => [_]*const fn (u32) callconv(.c) i32{ &remote.client, &remote.observer },
        .smp_floating => [_]*const fn (u32) callconv(.c) i32{ &duplex.floatingClient, &duplex.floatingObserver },
        .duplex, .cpu1_tasks, .cpu1_preemption, .cpu1_floating => [_]*const fn (u32) callconv(.c) i32{ &duplex.client, &duplex.observer },
    };
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
            .floating_context = if (mode == .smp_floating)
                @intCast(@intFromPtr(&floating_states[index]))
            else
                0,
        }) orelse return false;
    }
    if (mode == .ipc) ipc.prepare(
        .{ .slot = worker_handles[0].slot, .generation = worker_handles[0].generation },
        .{ .slot = worker_handles[1].slot, .generation = worker_handles[1].generation },
    );
    if (mode == .remote and !remote.prepare(
        .{ .slot = worker_handles[0].slot, .generation = worker_handles[0].generation },
        .{ .slot = worker_handles[1].slot, .generation = worker_handles[1].generation },
        ipi orelse return false,
    )) return false;
    if ((mode == .duplex or mode == .cpu1_tasks or mode == .cpu1_preemption or mode == .cpu1_floating or mode == .smp_floating) and !duplex.prepare(
        .{ .slot = worker_handles[0].slot, .generation = worker_handles[0].generation },
        .{ .slot = worker_handles[1].slot, .generation = worker_handles[1].generation },
        ipi orelse return false,
        switch (mode) {
            .cpu1_tasks => .task_service,
            .cpu1_preemption => .preemptive_tasks,
            .cpu1_floating => .floating_tasks,
            .smp_floating => .smp_floating,
            else => .interrupt_echo,
        },
    )) return false;
    if (mode == .smp_floating) {
        runtime.images[bootstrap_handle.slot].?.floating_context = @intCast(@intFromPtr(&bootstrap_floating));
        for (worker_handles, 0..) |handle, index| {
            floating_states[index] = std.mem.zeroes(context.FloatingContext);
            runtime.images[handle.slot].?.floating_context = @intCast(@intFromPtr(&floating_states[index]));
            runtime.images[handle.slot].?.state = .{ .mstatus = 0, .mcause = 0 };
        }
    }
    return timer.configureOneShot(period_us);
}

/// Called on CPU0 with MIE clear after installing the native vector and before
/// starting the timer. The bootstrap bank protects IDF's physical lazy owner.
pub fn beginWindow() void {
    nih_riscv_floating_saves[0] = 0;
    nih_riscv_floating_restores[0] = 0;
    const bank: u32 = if (mode == .smp_floating)
        @intCast(@intFromPtr(&bootstrap_floating))
    else
        0;
    nih_riscv_current_floating_states[0] = bank;
    nih_riscv_selected_floating_states[0] = bank;
    if (mode == .smp_floating) {
        const status = asm volatile ("csrr %[value], mstatus"
            : [value] "=r" (-> u32),
        );
        floating_initial_fs = (status >> 13) & 3;
        nih_riscv_fpu_snapshot(&boundary_before);
    }
}

/// Called on the restored bootstrap with MIE clear. Validate before clearing
/// per-hart FP ownership so no task bank can escape the native boundary.
pub fn finishWindow() bool {
    (device orelse return false).stop();
    const saves = nih_riscv_floating_saves[0];
    const restores = nih_riscv_floating_restores[0];
    if (mode == .smp_floating) {
        const status = asm volatile ("csrr %[value], mstatus"
            : [value] "=r" (-> u32),
        );
        floating_final_fs = (status >> 13) & 3;
        nih_riscv_fpu_snapshot(&boundary_after);
        const bank: u32 = @intCast(@intFromPtr(&bootstrap_floating));
        floating_boundary_restored = nih_riscv_current_floating_states[0] == bank and
            nih_riscv_selected_floating_states[0] == bank and
            floating_final_fs == floating_initial_fs and
            std.mem.eql(u8, std.mem.asBytes(&boundary_before), std.mem.asBytes(&boundary_after)) and
            saves == restores and saves == call_count + interrupt_count + floating_ipi_interrupts;
    } else {
        floating_boundary_restored = saves == 0 and restores == 0 and
            nih_riscv_current_floating_states[0] == 0 and nih_riscv_selected_floating_states[0] == 0;
    }
    nih_riscv_current_floating_states[0] = 0;
    nih_riscv_selected_floating_states[0] = 0;
    return floating_boundary_restored;
}

pub fn startMasked() bool {
    started_us = nih_platform_monotonic_us();
    (device orelse return false).start();
    if (mode == .remote) remote.start();
    if (mode == .duplex or mode == .cpu1_tasks or mode == .cpu1_preemption or mode == .cpu1_floating or mode == .smp_floating) duplex.start();
    return true;
}

pub fn run() bool {
    while (!finished.load(.monotonic)) {
        if (expired()) break;
        std.atomic.spinLoopHint();
    }
    const joined = joinRemote();
    (device orelse return false).stop();
    return joined and finished.load(.monotonic) and !failed.load(.monotonic);
}

pub fn joinRemote() bool {
    return switch (mode) {
        .remote => remote.stopAndJoin(),
        .duplex, .cpu1_tasks, .cpu1_preemption, .cpu1_floating, .smp_floating => duplex.stopAndJoin(),
        else => true,
    };
}

fn refreshClock() bool {
    const timer = device orelse return false;
    for (0..4) |_| {
        const now = timer.counter() orelse return false;
        const advance = clock.observe(now) orelse return false;
        if (!runtime.policy.elapse(advance.elapsed_ticks)) return false;
        if (mode == .smp_floating) duplex.noteCpu0Tick(runtime.policy.now());
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
    const current = runtime.policy.current() orelse return null;
    if (mode == .smp_floating) {
        for (worker_handles, 0..) |handle, index| {
            if (current.slot == handle.slot) floating_timer_captures[index] += 1;
        }
    }
    if (!(device orelse return null).clearPending() or !refreshClock()) return null;
    interrupt_count += 1;
    if (mode == .smp_floating) duplex.noteCpu0Timer(current.slot, runtime.policy.now());
    seedIntegerState(state);
    return checkedSelection(runtime.select() orelse return null);
}

fn seedIntegerState(state: context.ReturnState) void {
    if (!launched) {
        for (worker_handles) |handle| runtime.images[handle.slot].?.state =
            if (mode == .smp_floating) state.floatingReady() else state.integerOnly();
        launched = true;
    }
}

pub fn onIpi(frame: *context.IntegerContext, state: context.ReturnState) ?context.TaskContext {
    if ((mode != .remote and mode != .duplex and mode != .cpu1_tasks and mode != .cpu1_preemption and mode != .cpu1_floating and mode != .smp_floating) or !runtime.capture(frame, state)) return null;
    if (mode == .smp_floating) {
        floating_ipi_interrupts += 1;
        const current = runtime.policy.current() orelse return null;
        for (worker_handles, 0..) |handle, index| {
            if (current.slot == handle.slot) floating_ipi_captures[index] += 1;
        }
    }
    if (mode == .remote) remote.onIpi(&runtime.policy) else duplex.onIpi(&runtime.policy);
    if (!refreshClock()) return null;
    seedIntegerState(state);
    return checkedSelection(runtime.select() orelse return null);
}

pub fn onCall(frame: *context.IntegerContext, state: context.ReturnState) ?context.TaskContext {
    if (!refreshClock()) return null;
    call_count += 1;
    const caller = runtime.policy.current() orelse return null;
    if (mode == .smp_floating) for (worker_handles, 0..) |handle, index| {
        if (caller.slot == handle.slot) floating_call_captures[index] += 1;
    };
    const number = control.Number.decode(frame.a7);
    const argument = frame.a0;
    const selected = runtime.call(frame, state) orelse return null;
    if (mode == .remote and number == .wait_events) {
        const snapshot = runtime.policy.snapshot(caller) orelse return null;
        if (snapshot.state == .waiting) remote.recordBlocked(caller.slot, argument);
    }
    if ((mode == .duplex or mode == .cpu1_tasks or mode == .cpu1_preemption or mode == .cpu1_floating or mode == .smp_floating) and number == .wait_events) {
        const snapshot = runtime.policy.snapshot(caller) orelse return null;
        if (snapshot.state == .waiting) duplex.recordBlocked(caller.slot, argument);
    }
    if (mode == .ipc and number == .wait_events) {
        const snapshot = runtime.policy.snapshot(caller) orelse return null;
        if (snapshot.state == .waiting) ipc.recordBlocked(argument);
    }
    if (mode == .events and number == .wait_events) {
        const snapshot = runtime.policy.snapshot(caller) orelse return null;
        if (snapshot.state == .waiting) {
            blocked_events += 1;
            stage.store(1, .monotonic);
        } else if (frame.a1 == 0 and frame.a0 != 0) {
            immediate_events += 1;
        }
    }
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
    if (!finished.load(.monotonic) or failed.load(.monotonic)) return null;
    if (mode == .smp_floating and !floating_boundary_restored) return null;
    if ((mode == .lifecycle or mode == .events) and !terminal_wake_rejected.load(.monotonic)) return null;
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
        .immediate_events = immediate_events,
        .blocked_events = blocked_events,
        .delivered_events = delivered_events.load(.monotonic),
    };
    if (mode == .smp_floating) {
        var runtime_ticks = result.idle_runtime_ticks;
        for (worker_handles) |handle| {
            runtime_ticks = std.math.add(u64, runtime_ticks, (runtime.policy.snapshot(handle) orelse return null).runtime_ticks) catch return null;
        }
        if (runtime_ticks != runtime.policy.now() or clock.accounted_ticks != runtime.policy.now() or
            nih_riscv_current_floating_states[0] == @as(u32, @intCast(@intFromPtr(&floating_states[0]))) or
            nih_riscv_current_floating_states[0] == @as(u32, @intCast(@intFromPtr(&floating_states[1]))) or
            nih_riscv_selected_floating_states[0] == @as(u32, @intCast(@intFromPtr(&floating_states[0]))) or
            nih_riscv_selected_floating_states[0] == @as(u32, @intCast(@intFromPtr(&floating_states[1])))) return null;
        result.floating = .{
            .saves = nih_riscv_floating_saves[0],
            .restores = nih_riscv_floating_restores[0],
            .ipi_interrupts = floating_ipi_interrupts,
            .timer_captures = floating_timer_captures,
            .ipi_captures = floating_ipi_captures,
            .calls = floating_call_captures,
            .initial_fs = floating_initial_fs,
            .final_fs = floating_final_fs,
            .boundary_restored = floating_boundary_restored,
            .elapsed_ticks = clock.accounted_ticks,
            .runtime_ticks = runtime_ticks,
        };
    } else if (nih_riscv_floating_saves[0] != 0 or nih_riscv_floating_restores[0] != 0) {
        return null;
    }
    const expected_sleep: u32 = if (mode == .lifecycle) sleep_ticks else 2;
    if ((mode == .lifecycle or mode == .events) and (result.sleep_resumed < result.sleep_deadline or
        result.sleep_deadline != result.sleep_started + expected_sleep)) return null;
    switch (mode) {
        .lifecycle => if (result.idle_runtime_ticks < 2 or result.explicit_wakes != 1) return null,
        .events => if (result.immediate_events != 3 or result.blocked_events != 1 or
            result.delivered_events != 1) return null,
        .ipc => result.ipc = ipc.report() orelse return null,
        .remote => result.remote = remote.report() orelse return null,
        .duplex, .cpu1_tasks, .cpu1_preemption, .cpu1_floating, .smp_floating => result.duplex = duplex.report() orelse return null,
    }
    const replacement_image = runtime.images[worker_handles[0].slot] orelse return null;
    for (worker_handles, 0..) |handle, index| {
        const image = runtime.images[handle.slot] orelse return null;
        const address = switch (mode) {
            .ipc => ipc.stackAddress(index),
            .remote => remote.stackAddress(index),
            .duplex, .cpu1_tasks, .cpu1_preemption, .cpu1_floating, .smp_floating => duplex.stackAddress(index),
            else => stack_addresses[index].load(.monotonic),
        };
        const snapshot = runtime.policy.snapshot(handle) orelse return null;
        if (snapshot.state != .exited or address < image.stack_min or address >= image.stack_max)
            return null;
        result.exits[index] = snapshot.exit_code;
        if (!runtime.reap(handle)) return null;
        result.reaped += 1;
    }
    const expected_exits: [2]i32 = switch (mode) {
        .lifecycle => .{ 17, 37 },
        .events => .{ 41, 43 },
        .ipc => .{ 53, 59 },
        .remote => .{ 67, 71 },
        .duplex, .cpu1_tasks, .cpu1_preemption, .cpu1_floating, .smp_floating => .{ 73, 79 },
    };
    if (!std.mem.eql(i32, &result.exits, &expected_exits)) return null;
    // Reuse a reaped slot without executing it. The stale handle must not
    // affect the new ready task; its context storage belongs to this test.
    const replacement = runtime.add(0, replacement_image) orelse return null;
    if (replacement.slot != worker_handles[0].slot or
        replacement.generation == worker_handles[0].generation) return null;
    const stale = if (mode == .lifecycle)
        control.dispatch(&runtime.policy, @backingInt(control.Number.wake), control.encodeHandle(worker_handles[0]))
    else
        control.dispatchWithPayload(&runtime.policy, @backingInt(control.Number.notify), control.encodeHandle(worker_handles[0]), 1);
    if (stale.statusCode() != control.Status.not_found or
        runtime.policy.snapshot(replacement).?.state != .ready or
        runtime.policy.snapshot(replacement).?.pending_events != 0) return null;
    result.replacement_generation = replacement.generation;
    return result;
}
