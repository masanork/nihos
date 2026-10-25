//! Opt-in eager FP state. All Zig code in this module is integer-only.
const std = @import("std");
const context = @import("context.zig");
pub const enabled = @import("native_options").floating;
pub const compiled = @import("native_options").compiled;
pub const app = @import("compiled_fp.zig");
const calls = @import("task_calls.zig");
extern fn nih_native_task_failed() callconv(.c) noreturn;
extern fn nih_riscv_fpu_task_check(*context.FloatingProbe) callconv(.c) u32;
extern fn nih_riscv_fpu_snapshot(*context.FloatingContext) callconv(.c) void;
extern fn nih_riscv_fpu_task_probe(*context.FloatingProbe, *const fn (u32) callconv(.c) i32, u32) callconv(.c) noreturn;

export var nih_native_fp_current: [2]u32 = .{ 0, 0 };
export var nih_native_fp_selected: [2]u32 = .{ 0, 0 };
export var nih_native_fp_saves: [2]u32 = .{ 0, 0 };
export var nih_native_fp_restores: [2]u32 = .{ 0, 0 };

const bank_count = if (enabled) 2 else 0;
var banks: [bank_count][3]context.FloatingContext = @splat(@splat(.{ .f = @splat(0), .fcsr = 0 }));
var probes: [bank_count][3]context.FloatingProbe = @splat(@splat(.{ .pattern = 0, .expected_fcsr = 0 }));
var active: [bank_count][3]bool = @splat(@splat(false));
var retired_checks: [bank_count][3]u32 = @splat(@splat(0));
var starting_checks: [bank_count][3]u32 = @splat(@splat(0));

const Atomic = std.atomic.Value(u32);
const Published = struct {
    checks: [3]Atomic = @splat(.init(0)),
    timer: Atomic = .init(0),
    calls: Atomic = .init(0),
    ipi: Atomic = .init(0),
    saves: Atomic = .init(0),
    restores: Atomic = .init(0),
    confirmed: Atomic = .init(0),
    initial: Atomic = .init(0),
};
var published: [2]Published = .{ .{}, .{} };

pub const Report = struct {
    checks0: u32,
    checks1: u32,
    checks2: u32,
    timer: u32,
    calls: u32,
    ipi: u32,
    saves: u32,
    restores: u32,
    confirmed: u32,
    initial: u32,
    app_timer: u32,
};

pub fn prepare(hart: u32, index: u32, generation: u16, slot: u16) u32 {
    if (!enabled) return 0;
    if (active[hart][index]) nih_native_task_failed();
    banks[hart][index] = .{ .f = @splat(0), .fcsr = 0 };
    probes[hart][index] = .{
        .pattern = 0x3f80_0000 + hart * 0x100000 + index * 0x10000 + @as(u32, slot) * 0x1000 + @as(u32, generation) * 0x100,
        .expected_fcsr = if ((hart + index + generation) & 1 == 0) 1 else 33,
    };
    active[hart][index] = true;
    if (compiled) starting_checks[hart][index] = app.count(hart, index);
    return @intFromPtr(&banks[hart][index]);
}

pub fn enter(hart: u32, index: u32, entry: *const fn (u32) callconv(.c) i32, argument: u32) noreturn {
    if (!enabled) nih_native_task_failed();
    // SAFETY: the assembly snapshot writes all 132 bytes before any read.
    var initial: context.FloatingContext = undefined;
    nih_riscv_fpu_snapshot(&initial);
    if (initial.fcsr != 0) nih_native_task_failed();
    for (initial.f) |word| if (word != 0) nih_native_task_failed();
    _ = published[hart].initial.fetchAdd(1, .release);
    if (compiled) calls.exit(entry(argument));
    nih_riscv_fpu_task_probe(&probes[hart][index], entry, argument);
}

pub fn check(hart: u32, index: u32) void {
    if (!enabled) return;
    if (compiled) return app.checkpoint(hart, index);
    if (nih_riscv_fpu_task_check(&probes[hart][index]) == 0) nih_native_task_failed();
}

pub fn retire(hart: u32, index: u32) bool {
    if (!enabled) return true;
    if (compiled) {
        if (!active[hart][index] or app.count(hart, index) <= starting_checks[hart][index] or
            banks[hart][index].fcsr != app.expectedStatus(hart, index)) return false;
        active[hart][index] = false;
        return true;
    }
    if (!active[hart][index] or probes[hart][index].iterations == 0 or
        !context.matchesProbe(&banks[hart][index], &probes[hart][index])) return false;
    retired_checks[hart][index] +%= probes[hart][index].iterations;
    active[hart][index] = false;
    return true;
}

pub fn captured(hart: u32, bank: u32, kind: enum { timer, calls, ipi }, pc: u32) void {
    if (bank == 0) return;
    if (compiled and kind == .timer) app.captured(hart, pc);
    const counter = switch (kind) {
        .timer => &published[hart].timer,
        .calls => &published[hart].calls,
        .ipi => &published[hart].ipi,
    };
    _ = counter.fetchAdd(1, .release);
}

pub fn selectBank(hart: u32, bank: u32) void {
    nih_native_fp_selected[hart] = bank;
}

pub fn publish(hart: u32) void {
    if (!enabled) return;
    if (compiled) {
        for (0..3) |index| published[hart].checks[index].store(app.count(hart, @intCast(index)), .release);
        return;
    }
    for (0..3) |index| {
        const probe: *volatile context.FloatingProbe = &probes[hart][index];
        if (probe.failed != 0) nih_native_task_failed();
        const live = if (active[hart][index]) probe.iterations else 0;
        published[hart].checks[index].store(retired_checks[hart][index] +% live, .release);
    }
}

/// Called by each integer bootstrap after both protocol tasks have exited.
/// Its own final trap epilogue has completed, so copy counts are no longer
/// sampled half-way through a save/restore and no live task owns these banks.
pub fn quiesce(hart: u32) void {
    const status = asm volatile ("csrr %[value], mstatus"
        : [value] "=r" (-> u32),
    );
    if (status & 0x6000 != 0 or nih_native_fp_current[hart] != 0 or nih_native_fp_selected[hart] != 0)
        nih_native_task_failed();
    const saves = nih_native_fp_saves[hart];
    const restores = nih_native_fp_restores[hart];
    if (saves != restores) nih_native_task_failed();
    if (enabled) for (active[hart]) |value| if (value) nih_native_task_failed();
    publish(hart);
    published[hart].saves.store(saves, .release);
    published[hart].restores.store(restores, .release);
    published[hart].confirmed.store(1, .release);
}

pub fn report(hart: u32) Report {
    const source = &published[hart];
    return .{
        .checks0 = source.checks[0].load(.acquire),
        .checks1 = source.checks[1].load(.acquire),
        .checks2 = source.checks[2].load(.acquire),
        .timer = source.timer.load(.acquire),
        .calls = source.calls.load(.acquire),
        .ipi = source.ipi.load(.acquire),
        .saves = source.saves.load(.acquire),
        .restores = source.restores.load(.acquire),
        .confirmed = source.confirmed.load(.acquire),
        .initial = source.initial.load(.acquire),
        .app_timer = if (compiled) app.timerCaptures(hart) else 0,
    };
}
