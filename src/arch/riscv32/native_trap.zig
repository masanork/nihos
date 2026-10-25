//! Temporary native context-switch integration for the ESP-IDF oracle.
//!
//! One test switches to a separate Zig task stack through synchronous ecall.
//! Another enables one leased timer interrupt through the same trap entry;
//! other CPU0 sources remain pending until its bounded window ends.

const std = @import("std");
const context = @import("context.zig");
const trap = @import("trap.zig");
const timer_group = @import("timer_group");
const preemption = @import("preemption_test.zig");

const core_count = 2;
const interrupt_stack_bytes = 2048;
const task_stack_bytes = 4096;
const test_argument: u32 = 0x4e49_484f;

const SwitchState = enum(u32) {
    idle,
    launch,
    running,
    complete,
    timer,
    preemption,
};

var interrupt_stacks: [core_count][interrupt_stack_bytes]u8 align(16) = undefined;
var task_stack: [task_stack_bytes]u8 align(16) = undefined;
export var nih_riscv_interrupt_stack_bottoms: [core_count]u32 = @splat(0);
export var nih_riscv_interrupt_stack_tops: [core_count]u32 = @splat(0);
export var nih_riscv_selected_stack_mins: [core_count]u32 = @splat(0);
export var nih_riscv_selected_stack_maxs: [core_count]u32 = @splat(0);
export var nih_riscv_selected_return_states: [core_count]context.ReturnState =
    @splat(.{ .mstatus = 0, .mcause = 0 });
var switch_state: SwitchState = .idle;
var bootstrap_frame: ?*context.IntegerContext = null;
var task_frame: ?*context.IntegerContext = null;
var task_observation: u32 = 0;
var bootstrap_stack_min: u32 = 0;
var bootstrap_stack_max: u32 = 0;

const TimerLease = extern struct {
    group_address: u32,
    channel_id: u32,
    interrupt_id: u32,
};

pub const TimerReport = struct {
    ticks: u32,
    elapsed_us: u64,
    interrupt_id: u32,
    raw_mcause: u32,
};

const timer_period_us: u32 = 1000;
const timer_target_ticks: u32 = 32;
const timer_timeout_us: u64 = 100_000;
var timer_device: ?timer_group.Timer = null;
var timer_interrupt_id: u32 = 0;
var native_timer_ticks = std.atomic.Value(u32).init(0);
var native_timer_cause = std.atomic.Value(u32).init(0);
var native_timer_elapsed_us: u64 = 0;

extern fn nih_espidf_native_timer_acquire(out: *TimerLease) callconv(.c) i32;
extern fn nih_espidf_native_timer_release() callconv(.c) i32;
extern fn nih_riscv_timer_window() callconv(.c) u32;
extern fn nih_platform_monotonic_us() callconv(.c) u64;

extern fn nih_riscv_exception_roundtrip() callconv(.c) u32;
extern fn nih_riscv_task_trampoline() callconv(.c) void;
extern fn nih_riscv_context_test_yield() callconv(.c) noreturn;
extern fn nih_riscv_read_gp() callconv(.c) u32;
extern fn nih_riscv_read_tp() callconv(.c) u32;
extern fn esp_hw_stack_guard_get_bounds(
    core_id: u32,
    stack_min: *u32,
    stack_max: *u32,
) callconv(.c) void;

fn address32(pointer: anytype) ?u32 {
    const address = @intFromPtr(pointer);
    if (address > std.math.maxInt(u32)) return null;
    return @intCast(address);
}

fn contextTestTask(argument: u32) callconv(.c) void {
    task_observation = argument;
    nih_riscv_context_test_yield();
}

fn prepareInterruptStacks() bool {
    for (&interrupt_stacks, 0..) |*stack, core| {
        const bottom = @intFromPtr(stack);
        const top = @intFromPtr(stack) + stack.len;
        if (bottom > std.math.maxInt(u32) or top > std.math.maxInt(u32))
            return false;
        nih_riscv_interrupt_stack_bottoms[core] = @intCast(bottom);
        nih_riscv_interrupt_stack_tops[core] = @intCast(top);
    }
    return true;
}

pub fn exerciseContextSwitchRoundTrip() bool {
    if (!prepareInterruptStacks()) return false;

    const bottom = @intFromPtr(&task_stack);
    const top = @intFromPtr(&task_stack) + task_stack.len;
    if (bottom > std.math.maxInt(u32) or top > std.math.maxInt(u32))
        return false;
    const frame_address = (top - context.integer_context_size) &
        ~(@as(usize, context.stack_alignment) - 1);
    const initial_frame: *context.IntegerContext = @ptrFromInt(frame_address);
    const entry = address32(&contextTestTask) orelse return false;
    const trampoline = address32(&nih_riscv_task_trampoline) orelse return false;
    context.initialize(initial_frame, .{
        .entry = entry,
        .argument = test_argument,
        .trampoline = trampoline,
        .global_pointer = nih_riscv_read_gp(),
        .thread_pointer = nih_riscv_read_tp(),
    });

    bootstrap_frame = null;
    task_frame = initial_frame;
    task_observation = 0;
    esp_hw_stack_guard_get_bounds(0, &bootstrap_stack_min, &bootstrap_stack_max);
    if (bootstrap_stack_min >= bootstrap_stack_max) return false;
    switch_state = .launch;
    const returned = nih_riscv_exception_roundtrip() == 1;
    var restored_stack_min: u32 = 0;
    var restored_stack_max: u32 = 0;
    esp_hw_stack_guard_get_bounds(0, &restored_stack_min, &restored_stack_max);
    const complete = switch_state == .complete and
        task_observation == test_argument and bootstrap_frame != null and
        restored_stack_min == bootstrap_stack_min and
        restored_stack_max == bootstrap_stack_max;
    switch_state = .idle;
    bootstrap_frame = null;
    task_frame = null;
    return returned and complete;
}

/// IDF leases clocks, a channel and a CPU0 interrupt. nihOS controls the timer
/// MMIO and handles its non-vectored interrupt on the native trap stack.
fn acquireTimer() ?timer_group.Timer {
    if (!prepareInterruptStacks()) return null;
    var lease = std.mem.zeroes(TimerLease);
    if (nih_espidf_native_timer_acquire(&lease) != 0) return null;
    const device = timer_group.Timer.fromGroup(lease.group_address, lease.channel_id);
    if (device == null or lease.interrupt_id < 16 or lease.interrupt_id >= 48) {
        _ = nih_espidf_native_timer_release();
        return null;
    }
    timer_device = device;
    timer_interrupt_id = lease.interrupt_id;
    native_timer_ticks.store(0, .monotonic);
    native_timer_cause.store(0, .monotonic);
    esp_hw_stack_guard_get_bounds(0, &bootstrap_stack_min, &bootstrap_stack_max);
    return device;
}

fn finishTimer(returned: bool) bool {
    switch_state = .idle;
    (timer_device orelse return false).stop();
    var restored_min: u32 = 0;
    var restored_max: u32 = 0;
    esp_hw_stack_guard_get_bounds(0, &restored_min, &restored_max);
    timer_device = null;
    const released = nih_espidf_native_timer_release() == 0;
    return returned and released and restored_min == bootstrap_stack_min and
        restored_max == bootstrap_stack_max;
}

pub fn exerciseNativeTimer() ?TimerReport {
    const device = acquireTimer() orelse return null;
    const configured = device.configure(timer_period_us);
    switch_state = .timer;
    const returned = configured and nih_riscv_timer_window() == 1;
    if (!finishTimer(returned)) return null;
    return .{
        .ticks = native_timer_ticks.load(.monotonic),
        .elapsed_us = native_timer_elapsed_us,
        .interrupt_id = timer_interrupt_id,
        .raw_mcause = native_timer_cause.load(.monotonic),
    };
}

pub fn exerciseNativePreemption() ?preemption.Report {
    const device = acquireTimer() orelse return null;
    const trampoline = address32(&nih_riscv_task_trampoline) orelse {
        _ = finishTimer(false);
        return null;
    };
    const prepared = preemption.prepare(device, bootstrap_stack_min, bootstrap_stack_max, nih_riscv_read_gp(), nih_riscv_read_tp(), trampoline);
    switch_state = .preemption;
    const returned = prepared and nih_riscv_timer_window() == 1;
    const report = if (returned) preemption.report() else null;
    if (!finishTimer(returned)) return null;
    return report;
}

export fn nih_riscv_native_timer_prepare() callconv(.c) u32 {
    return if (switch_state != .preemption or preemption.startMasked()) 1 else 0;
}

export fn nih_riscv_native_timer_run() callconv(.c) u32 {
    if (switch_state == .preemption) return if (preemption.run()) 1 else 0;
    const device = timer_device orelse return 0;
    const started = nih_platform_monotonic_us();
    device.start();
    while (native_timer_ticks.load(.monotonic) < timer_target_ticks) {
        if (nih_platform_monotonic_us() - started >= timer_timeout_us) break;
        std.atomic.spinLoopHint();
    }
    device.stop();
    native_timer_elapsed_us = nih_platform_monotonic_us() - started;
    return if (native_timer_ticks.load(.monotonic) >= timer_target_ticks) 1 else 0;
}

export fn nih_riscv_trap_dispatch(
    interrupted: *context.IntegerContext,
    raw_mcause: u32,
    hart_id: u32,
    raw_mstatus: u32,
) callconv(.c) ?*context.IntegerContext {
    if (hart_id >= core_count) return null;
    const cause = trap.Cause.decode(raw_mcause);
    const return_state = context.ReturnState{ .mstatus = raw_mstatus, .mcause = raw_mcause };
    nih_riscv_selected_return_states[hart_id] = return_state;
    if (switch_state == .preemption) {
        if (hart_id != 0) return null;
        const selection = if (cause.kind == .interrupt and cause.reason == timer_interrupt_id)
            preemption.onTimer(interrupted, return_state)
        else if (cause.isException(.environment_call_from_machine))
            preemption.abort(interrupted, return_state)
        else
            null;
        const selected = selection orelse return null;
        nih_riscv_selected_stack_mins[hart_id] = selected.stack_min;
        nih_riscv_selected_stack_maxs[hart_id] = selected.stack_max;
        nih_riscv_selected_return_states[hart_id] = selected.state;
        return selected.frame;
    }
    if (switch_state == .timer) {
        if (hart_id != 0 or cause.kind != .interrupt or
            cause.reason != timer_interrupt_id) return null;
        const device = timer_device orelse return null;
        if (!device.acknowledge()) return null;
        native_timer_cause.store(raw_mcause, .monotonic);
        _ = native_timer_ticks.fetchAdd(1, .monotonic);
        nih_riscv_selected_stack_mins[hart_id] = bootstrap_stack_min;
        nih_riscv_selected_stack_maxs[hart_id] = bootstrap_stack_max;
        // Asynchronous interrupts resume the interrupted instruction unchanged.
        return interrupted;
    }
    if (!cause.isException(.environment_call_from_machine)) return null;
    if (interrupted.mepc > std.math.maxInt(u32) - 4) return null;
    interrupted.mepc += 4;

    return switch (switch_state) {
        .launch => next: {
            bootstrap_frame = interrupted;
            nih_riscv_selected_stack_mins[hart_id] =
                @intCast(@intFromPtr(&task_stack));
            nih_riscv_selected_stack_maxs[hart_id] =
                @intCast(@intFromPtr(&task_stack) + task_stack.len);
            switch_state = .running;
            break :next task_frame;
        },
        .running => next: {
            task_frame = interrupted;
            nih_riscv_selected_stack_mins[hart_id] = bootstrap_stack_min;
            nih_riscv_selected_stack_maxs[hart_id] = bootstrap_stack_max;
            switch_state = .complete;
            break :next bootstrap_frame;
        },
        .idle, .complete, .timer, .preemption => null,
    };
}
