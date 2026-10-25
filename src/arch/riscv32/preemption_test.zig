//! Bounded CPU0 preemption test. Two workers never normally yield;
//! the native timer selects their saved frames through kernel policy.

const std = @import("std");
const context = @import("context.zig");
const scheduler_module = @import("scheduler");
const tick_clock = @import("tick_clock");
const timer_group = @import("timer_group");

const Policy = scheduler_module.Scheduler(3, 2);
const worker_count = 2;
const stack_bytes = 4096;
const period_us = 1000;
const target_ticks = 32;
const delayed_first_us = 3500;
const timeout_us = 100_000;

pub const Mode = enum { integer, floating };

pub const Selection = struct {
    frame: *context.IntegerContext,
    state: context.ReturnState,
    stack_min: u32,
    stack_max: u32,
    floating_context: u32 = 0,
};

pub const Report = struct {
    elapsed_ticks: u64,
    interrupts: u32,
    caught_up_ticks: u64,
    elapsed_us: u64,
    bootstrap_runtime_ticks: u64,
    worker_iterations: [worker_count]u32,
    worker_selections: [worker_count]u32,
    worker_runtime_ticks: [worker_count]u64,
    floating_checks: [worker_count]u32 = @splat(0),
    floating_saves: u32 = 0,
    floating_restores: u32 = 0,
};

var stacks: [worker_count][stack_bytes]u8 align(16) = undefined;
var selections: [3]?Selection = @splat(null);
var policy: Policy = .{};
var clock = tick_clock.TickClock.init(period_us).?;
var bootstrap_handle = scheduler_module.TaskHandle{ .slot = 0, .generation = 0 };
var worker_handles: [worker_count]scheduler_module.TaskHandle = @splat(.{
    .slot = 0,
    .generation = 0,
});
var device: ?timer_group.Timer = null;
var original_stack_min: u32 = 0;
var original_stack_max: u32 = 0;
var interrupts: u32 = 0;
var caught_up_ticks: u64 = 0;
var selections_per_worker: [worker_count]u32 = @splat(0);
var iterations: [worker_count]std.atomic.Value(u32) = @splat(.init(0));
var stack_addresses: [worker_count]std.atomic.Value(u32) = @splat(.init(0));
var finished = std.atomic.Value(bool).init(false);
var failed = std.atomic.Value(bool).init(false);
var budget_started_us: u64 = 0;
var mode: Mode = .integer;
var bootstrap_floating_context: u32 = 0;
var floating_states: [worker_count]context.FloatingContext =
    @splat(std.mem.zeroes(context.FloatingContext));
var floating_probes: [worker_count]context.FloatingProbe = @splat(.{
    .pattern = 0,
    .expected_fcsr = 0,
});

extern fn nih_riscv_context_test_yield() callconv(.c) noreturn;
extern fn nih_platform_monotonic_us() callconv(.c) u64;
extern fn nih_riscv_fpu_probe_loop(probe: *context.FloatingProbe) callconv(.c) noreturn;

export fn nih_riscv_preemption_budget_expired() callconv(.c) u32 {
    return if (budgetExpired()) 1 else 0;
}

fn budgetExpired() bool {
    // The host's independent SYSTIMER oracle is only a test watchdog. Actual
    // scheduler time and deadlines always come from the native Timer Group.
    return nih_platform_monotonic_us() - budget_started_us >= timeout_us;
}

fn worker(argument: u32) callconv(.c) noreturn {
    if (argument >= worker_count) {
        failed.store(true, .monotonic);
        nih_riscv_context_test_yield();
    }
    if (mode == .floating) nih_riscv_fpu_probe_loop(&floating_probes[argument]);
    const marker = 0x6e69_6800 | argument;
    var canary: [4]u32 = @splat(marker);
    const checked: *volatile [4]u32 = &canary;
    stack_addresses[argument].store(@intCast(@intFromPtr(&canary)), .monotonic);
    var count: u32 = 0;
    while (true) {
        for (0..4) |index| {
            if (checked[index] != marker) failed.store(true, .monotonic);
        }
        count +%= 1;
        iterations[argument].store(count, .monotonic);
        // Recover to the bootstrap even if future timer interrupts disappear.
        // Normal execution never issues ecall or voluntarily yields.
        if (count & 255 == 0) {
            if (budgetExpired() or failed.load(.monotonic)) {
                failed.store(true, .monotonic);
                nih_riscv_context_test_yield();
            }
        }
    }
}

pub fn prepare(
    timer: timer_group.Timer,
    stack_min: u32,
    stack_max: u32,
    gp: u32,
    tp: u32,
    trampoline: u32,
    selected_mode: Mode,
    bootstrap_floating: u32,
) bool {
    device = timer;
    mode = selected_mode;
    bootstrap_floating_context = bootstrap_floating;
    policy = .{};
    clock = tick_clock.TickClock.init(period_us).?;
    selections = @splat(null);
    original_stack_min = stack_min;
    original_stack_max = stack_max;
    interrupts = 0;
    caught_up_ticks = 0;
    selections_per_worker = @splat(0);
    finished.store(false, .monotonic);
    failed.store(false, .monotonic);
    bootstrap_handle = policy.add(0) orelse return false;
    _ = policy.schedule() orelse return false;

    for (&stacks, 0..) |*stack, index| {
        floating_states[index] = std.mem.zeroes(context.FloatingContext);
        floating_probes[index] = .{
            .pattern = 0x3f80_0000 + @as(u32, @intCast(index)) * 0x1000,
            .expected_fcsr = 1 + @as(u32, @intCast(index)) * 32,
        };
        iterations[index].store(0, .monotonic);
        stack_addresses[index].store(0, .monotonic);
        const bottom: u32 = @intCast(@intFromPtr(stack));
        const frame_address = context.initialTaskFrameAddress(bottom, stack_bytes) orelse
            return false;
        const frame: *context.IntegerContext = @ptrFromInt(frame_address);
        context.initialize(frame, .{
            .entry = @intCast(@intFromPtr(&worker)),
            .argument = @intCast(index),
            .trampoline = trampoline,
            .global_pointer = gp,
            .thread_pointer = tp,
        });
        const handle = policy.add(1) orelse return false;
        worker_handles[index] = handle;
        selections[handle.slot] = .{
            .frame = frame,
            .state = .{ .mstatus = 0, .mcause = 0 },
            .stack_min = bottom,
            .stack_max = bottom + stack_bytes,
            .floating_context = if (mode == .floating)
                @intCast(@intFromPtr(&floating_states[index]))
            else
                0,
        };
    }
    return timer.configureOneShot(period_us);
}

/// Called before MIE is enabled. Intentionally delay the first pending alarm
/// so the target test must account for several ticks in one interrupt.
pub fn startMasked() bool {
    const timer = device orelse return false;
    budget_started_us = nih_platform_monotonic_us();
    timer.start();
    while (true) {
        const now = timer.counter() orelse return false;
        if (budgetExpired()) return false;
        if (now >= delayed_first_us) return true;
        std.atomic.spinLoopHint();
    }
}

pub fn run() bool {
    const timer = device orelse return false;
    while (!finished.load(.monotonic)) {
        if (budgetExpired()) break;
        std.atomic.spinLoopHint();
    }
    timer.stop();
    return finished.load(.monotonic) and !failed.load(.monotonic);
}

fn saveCurrent(frame: *context.IntegerContext, state: context.ReturnState) bool {
    const current = policy.current() orelse return false;
    var selected = selections[current.slot] orelse Selection{
        .frame = frame,
        .state = state,
        .stack_min = original_stack_min,
        .stack_max = original_stack_max,
        .floating_context = bootstrap_floating_context,
    };
    selected.frame = frame;
    selected.state = state;
    selections[current.slot] = selected;
    return true;
}

fn finish(success: bool) ?Selection {
    const timer = device orelse return null;
    timer.stop();
    if (!success) failed.store(true, .monotonic);
    finished.store(true, .monotonic);
    for (worker_handles) |handle| _ = policy.block(handle);
    _ = policy.wake(bootstrap_handle);
    const chosen = policy.schedule() orelse return null;
    if (chosen.slot != bootstrap_handle.slot) return null;
    return selections[chosen.slot];
}

pub fn abort(frame: *context.IntegerContext, state: context.ReturnState) ?Selection {
    if (!saveCurrent(frame, state)) return null;
    return finish(false);
}

pub fn onTimer(frame: *context.IntegerContext, state: context.ReturnState) ?Selection {
    const timer = device orelse return null;
    if (!saveCurrent(frame, state)) return null;
    if (!timer.clearPending()) return finish(false);
    if (interrupts == 0) {
        // Start integer-only tasks with the actual CPU privilege/CLIC return
        // state, disabling floating-point use until an FPU owner exists.
        for (worker_handles) |handle| {
            selections[handle.slot].?.state = if (mode == .floating)
                state.floatingReady()
            else
                state.integerOnly();
        }
    }
    interrupts += 1;

    // If arming itself crosses a deadline, catch up and rearm again. Both
    // retries and capture polling are bounded, including peripheral failure.
    for (0..4) |_| {
        const now = timer.counter() orelse return finish(false);
        const advance = clock.observe(now) orelse return finish(false);
        if (!policy.elapse(advance.elapsed_ticks)) return finish(false);
        if (policy.current()) |current| {
            if (current.slot == bootstrap_handle.slot and
                !policy.block(bootstrap_handle)) return finish(false);
        }
        if (advance.elapsed_ticks > 1) caught_up_ticks += advance.elapsed_ticks - 1;
        if (clock.accounted_ticks >= target_ticks) return finish(true);
        if (!timer.armAt(advance.next_deadline)) return finish(false);
        const after = timer.counter() orelse return finish(false);
        if (after < advance.next_deadline) {
            const chosen = policy.schedule() orelse return finish(false);
            for (worker_handles, 0..) |handle, index| {
                if (chosen.slot == handle.slot) selections_per_worker[index] += 1;
            }
            return selections[chosen.slot];
        }
        _ = timer.clearPending();
    }
    return finish(false);
}

pub fn report() ?Report {
    const timer = device orelse return null;
    const elapsed = timer.counter() orelse return null;
    if (!finished.load(.monotonic) or failed.load(.monotonic) or
        caught_up_ticks < 2 or clock.accounted_ticks < target_ticks or
        interrupts >= clock.accounted_ticks) return null;
    var result = Report{
        .elapsed_ticks = clock.accounted_ticks,
        .interrupts = interrupts,
        .caught_up_ticks = caught_up_ticks,
        .elapsed_us = elapsed,
        .bootstrap_runtime_ticks = (policy.snapshot(bootstrap_handle) orelse return null).runtime_ticks,
        .worker_iterations = @splat(0),
        .worker_selections = selections_per_worker,
        .worker_runtime_ticks = @splat(0),
    };
    var total_runtime = result.bootstrap_runtime_ticks;
    for (worker_handles, 0..) |handle, index| {
        const selected = selections[handle.slot] orelse return null;
        const address = if (mode == .floating) floating_probes[index].stack_address else stack_addresses[index].load(.monotonic);
        const count = if (mode == .floating) floating_probes[index].iterations else iterations[index].load(.monotonic);
        if (mode == .floating) {
            if (floating_probes[index].failed != 0) return null;
            result.floating_checks[index] = count;
        }
        if (address < selected.stack_min or address >= selected.stack_max or
            count == 0 or selections_per_worker[index] < 2) return null;
        result.worker_iterations[index] = count;
        result.worker_runtime_ticks[index] = (policy.snapshot(handle) orelse return null).runtime_ticks;
        total_runtime = std.math.add(u64, total_runtime, result.worker_runtime_ticks[index]) catch return null;
    }
    if (total_runtime != result.elapsed_ticks) return null;
    return result;
}
