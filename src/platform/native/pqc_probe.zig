//! Fixed public verification fixture; not a general-purpose crypto service.
const std = @import("std");
const memory = @import("native_tasks").memory;
extern fn nih_pqc_stack_call(usize) callconv(.c) c_int;

pub const Report = struct {
    status: u32 = 0,
    cycles: u32 = 0,
    masked_cycles: u32 = 0,
    ticks0: u32 = 0,
    ticks1: u32 = 0,
    lease: u32 = 0,
    stack_used: u32 = 0,
    guard: u32 = 0,
    erased: u32 = 0,
    released: u32 = 0,
    masked: u32 = 0,
};

pub noinline fn run() Report {
    var report: Report = .{};
    const allocation = memory.allocExternal(32768, 64) catch {
        report.status = 2; // PSRAM unavailable or quota exhausted.
        return report;
    };
    const stack = allocation.bytes;
    report.lease = @intCast(stack.len);
    @memset(stack, 0xa5);
    // Experimental only: current trap capture does not accept PSRAM frames.
    // This blocks local interrupts and is not suitable for an interactive service.
    const status = asm volatile ("csrrci %[out], mstatus, 8"
        : [out] "=r" (-> u32),
        :
        : .{ .memory = true });
    report.masked = @intFromBool(status & 8 != 0);
    const before = asm volatile ("rdcycle %[out]"
        : [out] "=r" (-> u32),
    );
    const result = nih_pqc_stack_call(@intFromPtr(stack.ptr) + stack.len);
    const after = asm volatile ("rdcycle %[out]"
        : [out] "=r" (-> u32),
    );
    report.masked_cycles = after -% before;
    if (status & 8 != 0) asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
    var first: usize = 256;
    while (first < stack.len and stack[first] == 0xa5) : (first += 1) {}
    report.stack_used = @intCast(stack.len - first);
    report.guard = @intFromBool(std.mem.allEqual(u8, stack[0..256], 0xa5));
    std.crypto.secureZero(u8, stack);
    report.erased = @intFromBool(std.mem.allEqual(u8, stack, 0));
    memory.freeExternal(allocation) catch {
        report.status = 3;
        return report;
    };
    report.released = 1;
    report.status = if (result == 0 and report.guard == 1 and report.erased == 1 and report.masked == 1 and report.stack_used > 0) 1 else 4;
    return report;
}
