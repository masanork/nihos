//! ILP32F task code. Floating instructions are confined to .fp_app.
const std = @import("std");
const calls = @import("task_calls.zig");
const vectors = @import("fp_vectors");
const enabled = @import("native_options").compiled;
extern fn nih_native_task_failed() callconv(.c) noreturn;
extern fn nih_fp_native_mismatch(u32, u32, u32) callconv(.c) noreturn;
extern fn nih_fp_native_stop() callconv(.c) u32;
extern fn nih_fp_native_progress(u32) callconv(.c) void;
extern fn nih_fp_native_slept(u32) callconv(.c) void;
extern fn nih_fp_native_protocol(u32) callconv(.c) i32;
extern var __fp_app_start: u8;
extern var __fp_app_end: u8;

const Pair = extern struct { x: f32, y: f32 };
extern fn nih_fp_c_mix(f32, f32, f32) callconv(.c) f32;
extern fn nih_fp_c_call_zig(f32, f32, f32) callconv(.c) f32;
extern fn nih_fp_c_pair_into(*const Pair, f32, *Pair) callconv(.c) void;
extern fn nih_fp_c_round(f32) callconv(.c) f32;
const Atomic = std.atomic.Value(u32);
var checks: [2][3]Atomic = @splat(@splat(.init(0)));
var captured_timers: [2]Atomic = @splat(.init(0));

comptime {
    if (@sizeOf(Pair) != 8 or @alignOf(Pair) != 4 or @offsetOf(Pair, "y") != 4)
        @compileError("compiled FP pair ABI changed");
    if (enabled) @export(&zigMix, .{ .name = "nih_fp_zig_mix" });
}

fn zigMix(a: f32, b: f32, c: f32) linksection(".fp_app") callconv(.c) f32 {
    @setFloatMode(.strict);
    return ((a * b) + c) * 0.5;
}

pub fn expectedStatus(hart: u32, index: u32) u32 {
    return ((hart + index) & 1) * 32 + 1;
}

fn begin(hart: u32, index: u32) linksection(".fp_app") void {
    const status = expectedStatus(hart, index) & ~@as(u32, 31);
    asm volatile ("csrw fcsr, %[value]"
        :
        : [value] "r" (status),
        : .{ .memory = true });
    checkpoint(hart, index);
}

fn requireBits(code: u32, actual: u32, expected: u32) void {
    if (actual != expected) nih_fp_native_mismatch(code, actual, expected);
}

fn pairInto(value: Pair, delta: f32) linksection(".fp_app") Pair {
    var result = Pair{ .x = 0, .y = 0 };
    nih_fp_c_pair_into(&value, delta, &result);
    return result;
}

pub fn checkpoint(hart: u32, index: u32) linksection(".fp_app") void {
    if (!enabled) return;
    const i: u4 = @truncate(checks[hart][index].load(.monotonic));
    const a = @as(f32, @floatFromInt(@as(u32, i) + 1)) * 0.25;
    const b = @as(f32, @floatFromInt(@as(u32, i) + 2)) * 0.5;
    const c = @as(f32, @floatFromInt(@as(u32, i) + 3)) * 0.125;
    const expected = vectors.mixBits(i);
    requireBits(1, @bitCast(nih_fp_c_mix(a, b, c)), expected);
    requireBits(2, @bitCast(zigMix(a, b, c)), expected);
    requireBits(3, @bitCast(nih_fp_c_call_zig(a, b, c)), expected);
    const pair = pairInto(.{ .x = a, .y = -a }, 0.25);
    const pair_bits = vectors.sixteenthsBits((@as(u16, i) + 2) * 4);
    requireBits(4, @bitCast(pair.x), pair_bits);
    requireBits(5, @bitCast(pair.y), pair_bits | 0x8000_0000);
    const rounded: u32 = @bitCast(nih_fp_c_round(1.0));
    const expected_round: u32 = if (expectedStatus(hart, index) == 1) 0x3f80_0002 else 0x3f80_0001;
    const status = asm volatile ("csrr %[value], fcsr"
        : [value] "=r" (-> u32),
    );
    requireBits(6, rounded, expected_round);
    requireBits(7, status, expectedStatus(hart, index));
    _ = checks[hart][index].fetchAdd(1, .release);
}

pub fn busy(argument: u32) linksection(".fp_app") callconv(.c) i32 {
    const hart = argument / 4;
    const index = argument % 4;
    begin(hart, index);
    var carry: f32 = 0.25;
    while (nih_fp_native_stop() == 0) {
        const pair = pairInto(.{ .x = carry, .y = -carry }, 0.25);
        if (pair.x != carry + 0.25 or pair.y != -carry - 0.25) nih_native_task_failed();
        carry = if (carry >= 4.0) 0.25 else pair.x;
        checkpoint(hart, index);
        nih_fp_native_progress(argument);
    }
    checkpoint(hart, index);
    return @intCast(100 + argument);
}

pub fn lifecycle(argument: u32) linksection(".fp_app") callconv(.c) i32 {
    const hart = argument / 4;
    begin(hart, 2);
    const x = nih_fp_c_mix(@floatFromInt(argument + 1), 0.5, 0.25);
    const before = calls.nowTicks();
    const duration: u32 = if (argument % 4 == 2) 3 else 1;
    if (calls.current() == null or calls.sleep(duration) != 0 or calls.nowTicks() - before < duration)
        nih_native_task_failed();
    checkpoint(hart, 2);
    if (x != nih_fp_c_mix(@floatFromInt(argument + 1), 0.5, 0.25)) nih_native_task_failed();
    nih_fp_native_slept(hart);
    if (calls.yieldNow() != 0) nih_native_task_failed();
    checkpoint(hart, 2);
    return @intCast(40 + argument);
}

pub fn protocol(hart: u32) linksection(".fp_app") callconv(.c) i32 {
    begin(hart, 2);
    const x = nih_fp_c_mix(@floatFromInt(hart + 5), 0.5, 0.25);
    const code = nih_fp_native_protocol(hart);
    checkpoint(hart, 2);
    if (x != nih_fp_c_mix(@floatFromInt(hart + 5), 0.5, 0.25)) nih_native_task_failed();
    return code;
}

pub fn count(hart: u32, index: u32) u32 {
    return checks[hart][index].load(.acquire);
}

pub fn captured(hart: u32, pc: u32) void {
    if (pc >= @intFromPtr(&__fp_app_start) and pc < @intFromPtr(&__fp_app_end))
        _ = captured_timers[hart].fetchAdd(1, .release);
}

pub fn timerCaptures(hart: u32) u32 {
    return captured_timers[hart].load(.acquire);
}
