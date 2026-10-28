//! One-shot stack-bank reuse; descriptor/gate and all IRQ paths stay SRAM.
const std = @import("std");
const lifetime = @import("font_stack_lifetime");
const composer = @import("native_surface.zig");
const surface = @import("surface");
extern var __graphics_font_stack_bottom: u8;
extern var __graphics_font_stack_top: u8;
extern fn nih_native_task_failed() callconv(.c) noreturn;
var gate = lifetime.Gate{};
var font: ?lifetime.Lease = null;
var previous: ?lifetime.Lease = null;
const none = lifetime.Proof{ .acknowledged = false, .exited = false, .cleaned = false, .reaped = false };
pub const Report = struct { bytes: u32 = 32768, loans: u32 = 0, guards: u32 = 0, busy: u32 = 0, stale: u32 = 0, premature: u32 = 0, returned: u32 = 0, before_hash: u32 = 0, after_hash: u32 = 0, paint_pc: u32 = 0, start: u32 = 0, end: u32 = 0 };
pub var metrics: Report = .{};
const mask linksection(".flash.rodata.display") = [_]u8{ 0, 64, 128, 255 };

pub noinline fn scratch() void {
    if (!composer.contextAllowed()) nih_native_task_failed();
    const lease = gate.claim(.scratch) catch nih_native_task_failed();
    if (gate.claim(.font)) |_| nih_native_task_failed() else |err| {
        if (err != error.Busy) nih_native_task_failed();
        metrics.busy += 1;
    }
    if (previous) |old| {
        if (gate.check(old)) |_| nih_native_task_failed() else |err| {
            if (err != error.Stale) nih_native_task_failed();
            metrics.stale += 1;
        }
    }
    gate.check(lease) catch nih_native_task_failed();
    const low = @intFromPtr(&__graphics_font_stack_bottom);
    if (@intFromPtr(&__graphics_font_stack_top) - low != 32768) nih_native_task_failed();
    metrics.start = low;
    metrics.end = @intFromPtr(&__graphics_font_stack_top);
    const bank: *[32768]u8 = @ptrFromInt(low);
    const hash = paint(bank);
    if (!composer.contextAllowed()) nih_native_task_failed();
    if (metrics.loans == 0) metrics.before_hash = hash else metrics.after_hash = hash;
    gate.release(lease, none) catch nih_native_task_failed();
    previous = lease;
    metrics.loans += 1;
    if (!@import("native_memory").stacks.bootGuardsIntact(0)) nih_native_task_failed();
    metrics.guards += 1;
}
pub fn prepare() bool {
    scratch();
    font = gate.claim(.font) catch return false;
    if (gate.claim(.scratch)) |_| return false else |err| {
        if (err != error.Busy) return false;
        metrics.busy += 1;
    }
    if (gate.release(font.?, none)) |_| return false else |err| {
        if (err != error.Quiescence) return false;
        metrics.premature += 1;
    }
    return true;
}
/// Called in the scheduler's masked post-reap path. Metadata only, no payload.
pub noinline fn reaped(proof: lifetime.Proof) bool {
    gate.release(font orelse return false, proof) catch return false;
    font = null;
    metrics.returned = 1;
    return true;
}

// Borrowed pixels only; SRAM caller owns the lease and context/stack guards.
noinline fn paint(bank: *[32768]u8) linksection(".flash.text.render") u32 {
    metrics.paint_pc = asm volatile ("auipc %[pc], 0"
        : [pc] "=r" (-> u32),
    );
    @memset(bank, 0xa5);
    const pixels = bank[64..][0..24576];
    const target = surface.Surface.init(pixels, 128, 96, 256) orelse nih_native_task_failed();
    if (!target.fill(0x1234) or !target.blit(.{ .bytes = &mask, .width = 2, .height = 2, .stride = 2 }, 3, 4, 0xffff)) nih_native_task_failed();
    if (!std.mem.allEqual(u8, bank[0..64], 0xa5) or !std.mem.allEqual(u8, bank[64 + 24576 ..], 0xa5)) nih_native_task_failed();
    var hash: u32 = 2166136261;
    for (pixels) |byte| hash = (hash ^ byte) *% 16777619;
    return hash;
}
