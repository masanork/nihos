//! A separate owner-local runtime on CPU1. Interrupt tails only deliver
//! events and select frames; the service callback runs on a native task stack.
const std = @import("std");
const context = @import("context.zig");
const Runtime = @import("task_runtime.zig").Runtime(3, 2);
const calls = @import("task_calls.zig");
const control = @import("task_control");
const scheduler = @import("scheduler");
const timer_group = @import("timer_group");
const tick_clock = @import("tick_clock");

pub const request_bit: u32 = 1;
const observer_bit: u32 = 2;
const acknowledgement_bit: u32 = 4;
const stop_bit: u32 = 0x8000_0000;
const stack_bytes = 4096;
const period_us: u32 = 1000;
const delayed_first_us: u64 = 3500;
const probe_sleep_ticks: u32 = 5;
pub const Mode = enum { integer, floating };
pub const Hooks = struct { work: *const fn () bool };
pub const Report = struct {
    syscalls: u32,
    selections: u32,
    switches: u32,
    ipi_task_captures: u32,
    ipi_interrupts: u32,
    observer_rounds: u32,
    delivered: u32,
    rejected: u32,
    reaped: u32,
    replacement_generation: u16,
    timer_interrupts: u32,
    timer_task_captures: u32,
    timer_caught_up_ticks: u64,
    elapsed_ticks: u64,
    runtime_ticks: u64,
    sleep_started: u64,
    sleep_deadline: u64,
    sleep_resumed: u64,
    probe_iterations: u32,
    probe_timer_wake: bool,
    floating_saves: u32,
    floating_restores: u32,
    floating_checks: [2]u32,
    floating_timer_captures: [2]u32,
    floating_ipi_captures: [2]u32,
    floating_calls: [2]u32,
    floating_boundary_restored: bool,
    floating_initial_fs: u32,
    floating_final_fs: u32,
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
var device: ?timer_group.Timer = null;
var clock = tick_clock.TickClock.init(period_us).?;
var timer_interrupts: u32 = 0;
var timer_task_captures: u32 = 0;
var timer_caught_up_ticks: u64 = 0;
var sleep_started: u64 = 0;
var sleep_deadline: u64 = 0;
var sleep_resumed: u64 = 0;
var probe_complete = std.atomic.Value(bool).init(false);
var probe_iterations = std.atomic.Value(u32).init(0);
var probe_timer_wake = false;
var mode: Mode = .integer;
var bootstrap_floating = std.mem.zeroes(context.FloatingContext);
var floating_states: [2]context.FloatingContext = @splat(std.mem.zeroes(context.FloatingContext));
var floating_probes: [2]context.FloatingProbe = @splat(.{ .pattern = 0, .expected_fcsr = 0 });
var boundary_before = std.mem.zeroes(context.FloatingContext);
var boundary_after = std.mem.zeroes(context.FloatingContext);
var boundary_fs: u32 = 0;
var boundary_final_fs: u32 = 0;
var boundary_restored = false;
var ipi_interrupts: u32 = 0;
var floating_timer_captures: [2]u32 = @splat(0);
var floating_ipi_captures: [2]u32 = @splat(0);
var floating_calls: [2]u32 = @splat(0);
var floating_ipi_ready = std.atomic.Value(bool).init(false);
var floating_ipi_seen = std.atomic.Value(bool).init(false);

extern var nih_riscv_current_floating_states: [2]u32;
extern var nih_riscv_selected_floating_states: [2]u32;
extern var nih_riscv_floating_saves: [2]u32;
extern var nih_riscv_floating_restores: [2]u32;
extern fn nih_riscv_fpu_snapshot(out: *context.FloatingContext) callconv(.c) void;
extern fn nih_riscv_fpu_task_probe(probe: *context.FloatingProbe, entry: *const fn (u32) callconv(.c) i32, argument: u32) callconv(.c) noreturn;
extern fn nih_riscv_fpu_task_check(probe: *context.FloatingProbe) callconv(.c) u32;

extern fn nih_platform_cpu_id() callconv(.c) u32;
extern fn nih_platform_monotonic_us() callconv(.c) u64;

fn fail(code: i32) noreturn {
    failed.store(true, .release);
    calls.exit(code);
}

fn checkFloating(index: usize) void {
    if (mode == .floating and nih_riscv_fpu_task_check(&floating_probes[index]) != 1) fail(-194);
}

fn wait(index: usize, mask: u32) u32 {
    checkFloating(index);
    const bits = switch (calls.waitEvents(mask)) {
        .received => |bits| bits,
        .failed => fail(-180),
    };
    checkFloating(index);
    return bits;
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
    checkFloating(0);
    if (device != null) {
        if (!probe_complete.load(.acquire)) {
            if (calls.sleep(probe_sleep_ticks) != calls.Status.ok) fail(-184);
            sleep_resumed = calls.nowTicks();
            checkFloating(0);
            if (sleep_resumed < sleep_deadline or probe_iterations.load(.monotonic) == 0) fail(-192);
            check(checked, 0x6331_7376);
            probe_complete.store(true, .release);
        }
    } else if (calls.sleep(1) != calls.Status.not_supported) fail(-184);
    while (true) {
        if (wait(0, request_bit | stop_bit) & stop_bit != 0) break;
        const peer = calls.Handle{ .slot = handles[1].slot, .generation = handles[1].generation };
        if (calls.notify(peer, observer_bit) != calls.Status.ok) fail(-185);
        checkFloating(0);
        if (wait(0, acknowledgement_bit | stop_bit) & stop_bit != 0) break;
        if (!(hooks orelse fail(-186)).work()) fail(-187);
        check(checked, 0x6331_7376);
        if (calls.yieldNow() != calls.Status.ok) fail(-188);
        checkFloating(0);
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
    checkFloating(1);
    if (device != null) {
        // No ECALL, yield, or clock query in this loop. Only CPU1 timer
        // preemption can make the sleeping service run at its deadline.
        var count: u32 = 0;
        floating_ipi_ready.store(mode == .floating, .release);
        while (!probe_complete.load(.acquire) or (mode == .floating and !floating_ipi_seen.load(.acquire))) {
            count +%= 1;
            probe_iterations.store(count, .monotonic);
            if (count & 255 == 0) {
                check(checked, 0x6331_6f62);
                checkFloating(1);
            }
        }
        check(checked, 0x6331_6f62);
    }
    while (true) {
        if (wait(1, observer_bit | stop_bit) & stop_bit != 0) break;
        _ = observer_rounds.fetchAdd(1, .monotonic);
        const peer = calls.Handle{ .slot = handles[0].slot, .generation = handles[0].generation };
        if (calls.notify(peer, acknowledgement_bit) != calls.Status.ok) fail(-191);
        checkFloating(1);
        check(checked, 0x6331_6f62);
    }
    check(checked, 0x6331_6f62);
    return 89;
}

fn floatingService(argument: u32) callconv(.c) i32 {
    nih_riscv_fpu_task_probe(&floating_probes[0], &service, argument);
}

fn floatingObserver(argument: u32) callconv(.c) i32 {
    nih_riscv_fpu_task_probe(&floating_probes[1], &observer, argument);
}

pub fn floatingProbeReady() bool {
    return floating_ipi_ready.load(.acquire);
}

/// Called on CPU1, before installing its native vector or publishing ready.
pub fn prepare(minimum: u32, maximum: u32, gp: u32, tp: u32, trampoline: u32, callbacks: Hooks, timer: ?timer_group.Timer, selected_mode: Mode) bool {
    runtime = .{ .call_options = .{ .sleep_enabled = timer != null } };
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
    device = timer;
    mode = selected_mode;
    if (mode == .floating and timer == null) return false;
    floating_timer_captures = @splat(0);
    floating_ipi_captures = @splat(0);
    floating_calls = @splat(0);
    ipi_interrupts = 0;
    boundary_restored = false;
    boundary_fs = 0;
    boundary_final_fs = 0;
    floating_ipi_ready.store(false, .monotonic);
    floating_ipi_seen.store(false, .monotonic);
    clock = tick_clock.TickClock.init(period_us).?;
    timer_interrupts = 0;
    timer_task_captures = 0;
    timer_caught_up_ticks = 0;
    sleep_started = 0;
    sleep_deadline = 0;
    sleep_resumed = 0;
    probe_complete.store(false, .monotonic);
    probe_iterations.store(0, .monotonic);
    probe_timer_wake = false;
    bootstrap = runtime.add(1, .{ .stack_min = minimum, .stack_max = maximum, .floating_context = if (mode == .floating) @intCast(@intFromPtr(&bootstrap_floating)) else 0 }) orelse return false;
    last_slot = bootstrap.slot;
    _ = runtime.policy.schedule() orelse return false;
    const entries = if (mode == .floating)
        [_]*const fn (u32) callconv(.c) i32{ &floatingService, &floatingObserver }
    else
        [_]*const fn (u32) callconv(.c) i32{ &service, &observer };
    for (&stacks, entries, 0..) |*stack, entry, index| {
        floating_states[index] = std.mem.zeroes(context.FloatingContext);
        floating_probes[index] = .{
            .pattern = 0x3fa0_0000 + @as(u32, @intCast(index)) * 0x1000,
            .expected_fcsr = 1 + @as(u32, @intCast(index)) * 32,
        };
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
        handles[index] = runtime.add(0, .{
            .frame = frame,
            .stack_min = bottom,
            .stack_max = bottom + stack_bytes,
            .floating_context = if (mode == .floating) @intCast(@intFromPtr(&floating_states[index])) else 0,
        }) orelse return false;
    }
    return if (timer) |value| value.configureOneShot(period_us) else true;
}

/// MIE is clear and all other CPU1 sources are masked. Preserve the IDF lazy
/// owner's physical bank even if its FS status is Off; do not edit its TCB.
pub fn beginWindow() void {
    nih_riscv_floating_saves[1] = 0;
    nih_riscv_floating_restores[1] = 0;
    nih_riscv_current_floating_states[1] = if (mode == .floating) @intCast(@intFromPtr(&bootstrap_floating)) else 0;
    nih_riscv_selected_floating_states[1] = nih_riscv_current_floating_states[1];
    if (mode == .floating) {
        boundary_fs = asm volatile ("csrr %[value], mstatus"
            : [value] "=r" (-> u32),
        ) & 0x6000;
        nih_riscv_fpu_snapshot(&boundary_before);
    }
}

/// Runs on the restored bootstrap with MIE clear, before returning to IDF's
/// vector. A normal final selection must already have restored its FP bank.
pub fn finishWindow() bool {
    stopTimer();
    const saves = nih_riscv_floating_saves[1];
    const restores = nih_riscv_floating_restores[1];
    if (mode == .floating) {
        const after_fs = asm volatile ("csrr %[value], mstatus"
            : [value] "=r" (-> u32),
        ) & 0x6000;
        boundary_final_fs = after_fs;
        nih_riscv_fpu_snapshot(&boundary_after);
        boundary_restored = nih_riscv_current_floating_states[1] == @intFromPtr(&bootstrap_floating) and
            after_fs == boundary_fs and std.mem.eql(u8, std.mem.asBytes(&boundary_before), std.mem.asBytes(&boundary_after)) and
            saves == restores and saves == calls_count + timer_interrupts + ipi_interrupts;
    } else {
        boundary_restored = saves == 0 and restores == 0 and nih_riscv_current_floating_states[1] == 0;
    }
    nih_riscv_current_floating_states[1] = 0;
    nih_riscv_selected_floating_states[1] = 0;
    return boundary_restored;
}

/// Runs after vector installation with MIE clear. The initial 1ms alarm is
/// deliberately held pending until 3.5ms, before any task can query time.
pub fn startTimer() bool {
    const timer = device orelse return true;
    const started = nih_platform_monotonic_us();
    timer.start();
    while (true) {
        if ((timer.counter() orelse return false) >= delayed_first_us) return true;
        if (nih_platform_monotonic_us() - started >= 100_000) return false;
        std.atomic.spinLoopHint();
    }
}

pub fn stopTimer() void {
    if (device) |timer| timer.stop();
}

fn refreshClock() bool {
    const timer = device orelse return true;
    for (0..4) |_| {
        const now = timer.counter() orelse return false;
        const advance = clock.observe(now) orelse return false;
        const before = runtime.policy.snapshot(handles[0]) orelse return false;
        if (!runtime.policy.elapse(advance.elapsed_ticks)) return false;
        const after = runtime.policy.snapshot(handles[0]) orelse return false;
        if (before.state == .sleeping and after.state == .ready and !probe_complete.load(.acquire))
            probe_timer_wake = true;
        if (advance.elapsed_ticks > 1)
            timer_caught_up_ticks += advance.elapsed_ticks - 1;
        const next = advance.next_deadline;
        if (!timer.armAt(next)) return false;
        if ((timer.counter() orelse return false) < next) return true;
        _ = timer.clearPending();
    }
    return false;
}

fn seed(state: context.ReturnState) void {
    if (!launched) {
        for (handles) |handle| runtime.images[handle.slot].?.state = if (mode == .floating) state.floatingReady() else state.integerOnly();
        launched = true;
    }
}

pub fn onTimer(frame: *context.IntegerContext, state: context.ReturnState) ?context.TaskContext {
    if (!runtime.capture(frame, state)) return null;
    const current = runtime.policy.current() orelse return null;
    if (mode == .floating) for (handles, 0..) |handle, index| {
        if (current.slot == handle.slot) floating_timer_captures[index] += 1;
    };
    if ((runtime.policy.current() orelse return null).slot != bootstrap.slot) timer_task_captures += 1;
    if (!(device orelse return null).clearPending()) return null;
    timer_interrupts += 1;
    if (!refreshClock()) return null;
    seed(state);
    return selected(runtime.select() orelse return null);
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
    ipi_interrupts += 1;
    const current = runtime.policy.current() orelse return null;
    if (mode == .floating) for (handles, 0..) |handle, index| {
        if (current.slot == handle.slot) {
            floating_ipi_captures[index] += 1;
            if (index == 1 and floating_ipi_ready.load(.acquire)) floating_ipi_seen.store(true, .release);
        }
    };
    if ((runtime.policy.current() orelse return null).slot != bootstrap.slot) ipi_task_captures += 1;
    seed(state);
    const drained = inbox.drain(&runtime.policy, 4, doorbell);
    delivered += drained.delivered;
    rejected += drained.rejected;
    if (stopping) {
        // Release this fixture's non-yielding gate even on a failed timer,
        // and don't depend on that failed clock to wake an aborted sleeper.
        probe_complete.store(true, .release);
        floating_ipi_seen.store(true, .release);
        for (handles) |handle| {
            _ = runtime.policy.notify(handle, stop_bit);
            _ = runtime.policy.wake(handle);
        }
    }
    return selected(runtime.select() orelse return null);
}

pub fn onCall(frame: *context.IntegerContext, state: context.ReturnState) ?context.TaskContext {
    calls_count += 1;
    const caller = runtime.policy.current() orelse return null;
    if (mode == .floating) for (handles, 0..) |handle, index| {
        if (caller.slot == handle.slot) floating_calls[index] += 1;
    };
    const number = control.Number.decode(frame.a7);
    const selection = runtime.call(frame, state) orelse return null;
    if (number == .sleep and device != null and caller.slot == handles[0].slot) {
        const snapshot = runtime.policy.snapshot(caller) orelse return null;
        if (snapshot.state == .sleeping) {
            sleep_started = runtime.policy.now();
            sleep_deadline = snapshot.wake_tick;
        }
    }
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
    if (!finished.load(.acquire) or failed.load(.acquire) or !boundary_restored) return false;
    if (mode == .floating) {
        if (floating_timer_captures[1] == 0 or floating_ipi_captures[1] == 0) return false;
        for (floating_probes, floating_calls) |probe, count| {
            if (probe.failed != 0 or probe.iterations == 0 or count == 0) return false;
        }
    }
    var total_runtime = (runtime.policy.snapshot(bootstrap) orelse return false).runtime_ticks;
    for (handles) |handle| total_runtime = std.math.add(u64, total_runtime, (runtime.policy.snapshot(handle) orelse return false).runtime_ticks) catch return false;
    if (total_runtime != runtime.policy.now()) return false;
    if (device != null and (timer_interrupts < 2 or timer_task_captures == 0 or timer_caught_up_ticks == 0 or
        !probe_timer_wake or sleep_deadline != sleep_started + probe_sleep_ticks or sleep_resumed < sleep_deadline or
        probe_iterations.load(.monotonic) == 0)) return false;
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
        .ipi_interrupts = ipi_interrupts,
        .observer_rounds = observer_rounds.load(.monotonic),
        .delivered = delivered,
        .rejected = rejected,
        .reaped = reaped,
        .replacement_generation = replacement.generation,
        .timer_interrupts = timer_interrupts,
        .timer_task_captures = timer_task_captures,
        .timer_caught_up_ticks = timer_caught_up_ticks,
        .elapsed_ticks = runtime.policy.now(),
        .runtime_ticks = total_runtime,
        .sleep_started = sleep_started,
        .sleep_deadline = sleep_deadline,
        .sleep_resumed = sleep_resumed,
        .probe_iterations = probe_iterations.load(.monotonic),
        .probe_timer_wake = probe_timer_wake,
        .floating_saves = nih_riscv_floating_saves[1],
        .floating_restores = nih_riscv_floating_restores[1],
        .floating_checks = .{ floating_probes[0].iterations, floating_probes[1].iterations },
        .floating_timer_captures = floating_timer_captures,
        .floating_ipi_captures = floating_ipi_captures,
        .floating_calls = floating_calls,
        .floating_boundary_restored = boundary_restored,
        .floating_initial_fs = boundary_fs >> 13,
        .floating_final_fs = boundary_final_fs >> 13,
    };
    return true;
}

pub fn report() ?Report {
    return final_report;
}
