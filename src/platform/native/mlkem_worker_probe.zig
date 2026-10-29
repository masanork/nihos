//! Fixed public test-vector worker; not a production KEM service.
const std = @import("std");
const memory = @import("native_tasks").memory;
extern fn nih_sqlite_stack_paint(u32) callconv(.c) u32;
const Result = extern struct { key_ok: u32 = 0, enc_ok: u32 = 0, dec_ok: u32 = 0, implicit_ok: u32 = 0, oom_ok: u32 = 0, key_peak: u32 = 0, enc_peak: u32 = 0, dec_peak: u32 = 0, allocs: u32 = 0, frees: u32 = 0, oom_error: u32 = 0, live: u32 = 0, uncleared: u32 = 0, ticks: u32 = 0, foreground0: u32 = 0, foreground1: u32 = 0, key_stack: u32 = 0, enc_stack: u32 = 0, dec_stack: u32 = 0, implicit_stack: u32 = 0, oom_stack: u32 = 0 };
extern fn nih_mlkem_worker_fixture([*]u8, usize, [*]u8, usize, u32, u32, *Result) callconv(.c) c_int;
pub const Report = struct { status: u32 = 0, before: u32 = 0, after_arena: u32 = 0, after_both: u32 = 0, after_release: u32 = 0, arena: u32 = 0, io: u32 = 0, charged: u32 = 0, key_ok: u32 = 0, enc_ok: u32 = 0, dec_ok: u32 = 0, implicit_ok: u32 = 0, oom_ok: u32 = 0, key_peak: u32 = 0, enc_peak: u32 = 0, dec_peak: u32 = 0, allocs: u32 = 0, frees: u32 = 0, oom_error: u32 = 0, live: u32 = 0, uncleared: u32 = 0, ticks: u32 = 0, foreground0: u32 = 0, foreground1: u32 = 0, key_stack: u32 = 0, enc_stack: u32 = 0, dec_stack: u32 = 0, implicit_stack: u32 = 0, oom_stack: u32 = 0, stack_used: u32 = 0, stack_painted: u32 = 0, erased: u32 = 0, released: u32 = 0, mie: u32 = 0 };
pub noinline fn run(stack: memory.stacks.layout.Region) Report {
    var report: Report = .{};
    const before = memory.reusable.availableBytes() orelse {
        report.status = 2;
        return report;
    };
    const arena = memory.allocExternal(32688, 64) catch {
        report.status = 2;
        return report;
    };
    const after_arena = memory.reusable.availableBytes() orelse unreachable;
    const io = memory.allocExternal(6144, 64) catch {
        memory.freeExternal(arena) catch {
            report.status = 3;
            return report;
        };
        report.status = 2;
        return report;
    };
    const after_both = memory.reusable.availableBytes() orelse unreachable;
    report.before = @intCast(before);
    report.after_arena = @intCast(after_arena);
    report.after_both = @intCast(after_both);
    report.arena = @intCast(arena.bytes.len);
    report.io = @intCast(io.bytes.len);
    report.charged = @intCast(before - after_both);
    const low = stack.start + memory.stacks.layout.guard_bytes;
    const painted = nih_sqlite_stack_paint(low);
    report.stack_painted = painted;
    var result: Result = .{};
    const rc = nih_mlkem_worker_fixture(arena.bytes.ptr, arena.bytes.len, io.bytes.ptr, io.bytes.len, low, stack.end, &result);
    const status = asm volatile ("csrr %[out], mstatus"
        : [out] "=r" (-> u32),
    );
    report.mie = status & 8;
    var first = low;
    while (first < painted) : (first += 4) {
        const word: *const volatile u32 = @ptrFromInt(first);
        if (word.* != 0x5a7ec319) break;
    }
    report.stack_used = stack.end - first;
    report.key_ok = result.key_ok;
    report.enc_ok = result.enc_ok;
    report.dec_ok = result.dec_ok;
    report.implicit_ok = result.implicit_ok;
    report.oom_ok = result.oom_ok;
    report.key_peak = result.key_peak;
    report.enc_peak = result.enc_peak;
    report.dec_peak = result.dec_peak;
    report.allocs = result.allocs;
    report.frees = result.frees;
    report.oom_error = result.oom_error;
    report.live = result.live;
    report.uncleared = result.uncleared;
    report.ticks = result.ticks;
    report.foreground0 = result.foreground0;
    report.foreground1 = result.foreground1;
    report.key_stack = result.key_stack;
    report.enc_stack = result.enc_stack;
    report.dec_stack = result.dec_stack;
    report.implicit_stack = result.implicit_stack;
    report.oom_stack = result.oom_stack;
    report.stack_used = @max(report.stack_used, report.key_stack, report.enc_stack, report.dec_stack, report.implicit_stack, report.oom_stack);
    std.crypto.secureZero(u8, arena.bytes);
    std.crypto.secureZero(u8, io.bytes);
    report.erased = @intFromBool(std.mem.allEqual(u8, arena.bytes, 0) and std.mem.allEqual(u8, io.bytes, 0));
    memory.freeExternal(io) catch {
        report.status = 3;
        return report;
    };
    memory.freeExternal(arena) catch {
        report.status = 3;
        return report;
    };
    report.released = 1;
    report.after_release = @intCast(memory.reusable.availableBytes() orelse return report);
    report.status = if (rc == 0 and first > low and report.mie == 8 and report.erased == 1 and report.before == report.after_release) 1 else 4;
    return report;
}
