//! Temporary native context-switch integration for the ESP-IDF oracle.
//!
//! The self-test installs the nihOS vector only while maskable interrupts are
//! disabled. One `ecall` leaves the ESP-IDF task, runs a Zig function on a
//! separate stack, and a second `ecall` restores the original context.

const std = @import("std");
const context = @import("context.zig");
const trap = @import("trap.zig");

const core_count = 2;
const interrupt_stack_bytes = 2048;
const task_stack_bytes = 4096;
const test_argument: u32 = 0x4e49_484f;

const SwitchState = enum(u32) {
    idle,
    launch,
    running,
    complete,
};

var interrupt_stacks: [core_count][interrupt_stack_bytes]u8 align(16) = undefined;
var task_stack: [task_stack_bytes]u8 align(16) = undefined;
export var nih_riscv_interrupt_stack_tops: [core_count]u32 = @splat(0);
var switch_state: SwitchState = .idle;
var bootstrap_frame: ?*context.IntegerContext = null;
var task_frame: ?*context.IntegerContext = null;
var task_observation: u32 = 0;

extern fn nih_riscv_exception_roundtrip() callconv(.c) u32;
extern fn nih_riscv_task_trampoline() callconv(.c) void;
extern fn nih_riscv_context_test_yield() callconv(.c) noreturn;
extern fn nih_riscv_read_gp() callconv(.c) u32;
extern fn nih_riscv_read_tp() callconv(.c) u32;

fn address32(pointer: anytype) ?u32 {
    const address = @intFromPtr(pointer);
    if (address > std.math.maxInt(u32)) return null;
    return @intCast(address);
}

fn contextTestTask(argument: u32) callconv(.c) void {
    task_observation = argument;
    nih_riscv_context_test_yield();
}

pub fn exerciseContextSwitchRoundTrip() bool {
    for (&interrupt_stacks, 0..) |*stack, core| {
        const top = @intFromPtr(stack) + stack.len;
        if (top > std.math.maxInt(u32)) return false;
        nih_riscv_interrupt_stack_tops[core] = @intCast(top);
    }

    const top = @intFromPtr(&task_stack) + task_stack.len;
    if (top > std.math.maxInt(u32)) return false;
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
    switch_state = .launch;
    const returned = nih_riscv_exception_roundtrip() == 1;
    const complete = switch_state == .complete and
        task_observation == test_argument and bootstrap_frame != null;
    switch_state = .idle;
    bootstrap_frame = null;
    task_frame = null;
    return returned and complete;
}

export fn nih_riscv_trap_dispatch(
    interrupted: *context.IntegerContext,
    raw_mcause: u32,
    hart_id: u32,
) callconv(.c) ?*context.IntegerContext {
    if (hart_id >= core_count) return null;
    const cause = trap.Cause.decode(raw_mcause);
    if (!cause.isException(.environment_call_from_machine)) return null;
    if (interrupted.mepc > std.math.maxInt(u32) - 4) return null;
    interrupted.mepc += 4;

    return switch (switch_state) {
        .launch => next: {
            bootstrap_frame = interrupted;
            switch_state = .running;
            break :next task_frame;
        },
        .running => next: {
            task_frame = interrupted;
            switch_state = .complete;
            break :next bootstrap_frame;
        },
        .idle, .complete => null,
    };
}
