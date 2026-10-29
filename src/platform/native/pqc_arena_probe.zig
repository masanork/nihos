//! Preemptible public verification fixture. Not a production crypto service.
const std = @import("std");
const memory = @import("native_tasks").memory;
extern fn nih_sqlite_stack_paint(u32) callconv(.c) u32;
const Result = extern struct { valid: u32 = 0, rejected: u32 = 0, oom: u32 = 0, peak: u32 = 0, allocs: u32 = 0, frees: u32 = 0, failures: u32 = 0, live: u32 = 0, verify_ticks: u32 = 0, verify_worker0: u32 = 0, verify_worker1: u32 = 0 };
extern fn nih_pqc_arena_fixture([*]u8, usize, *Result) callconv(.c) c_int;
extern fn nih_pqc_snapshot_fixture([*]u8, usize, [*]u8, usize, *Result) callconv(.c) c_int;

pub const Report = struct {
    status: u32 = 0,
    cycles: u32 = 0,
    ticks0: u32 = 0,
    ticks1: u32 = 0,
    worker0: u32 = 0,
    worker1: u32 = 0,
    verify_ticks: u32 = 0,
    verify_worker0: u32 = 0,
    verify_worker1: u32 = 0,
    heap_before: u32 = 0,
    heap_after: u32 = 0,
    charged: u32 = 0,
    lease: u32 = 0,
    peak: u32 = 0,
    allocs: u32 = 0,
    frees: u32 = 0,
    failures: u32 = 0,
    valid: u32 = 0,
    rejected: u32 = 0,
    oom: u32 = 0,
    live: u32 = 0,
    stack_used: u32 = 0,
    stack_painted: u32 = 0,
    erased: u32 = 0,
    released: u32 = 0,
    mie: u32 = 0,
};

pub noinline fn run() Report {
    return runOn(memory.stacks.layout.bootstrap(0).?);
}

pub noinline fn runOn(stack: memory.stacks.layout.Region) Report {
    return runOnMode(stack, false, null);
}

/// Fixture only: retain the owned allocation so exit cleanup must drain it.
pub noinline fn runOnMode(stack: memory.stacks.layout.Region, retain: bool, snapshot: ?[]u8) Report {
    var report: Report = .{};
    // Bound the accounting snapshot and allocation against local preemption.
    // Verification below runs with the original MIE state restored.
    const allocation = blk: {
        const status = asm volatile ("csrrci %[out], mstatus, 8"
            : [out] "=r" (-> u32),
            :
            : .{ .memory = true });
        defer if (status & 8 != 0) asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
        const before = memory.reusable.availableBytes() orelse {
            report.status = 2;
            return report;
        };
        const value = memory.allocExternal(16304, 64) catch {
            report.status = 2;
            return report;
        };
        const after = memory.reusable.availableBytes() orelse {
            memory.freeExternal(value) catch {};
            report.status = 3;
            return report;
        };
        if (after > before) {
            memory.freeExternal(value) catch {};
            report.status = 3;
            return report;
        }
        report.heap_before = @intCast(before);
        report.heap_after = @intCast(after);
        report.charged = @intCast(before - after);
        break :blk value;
    };
    report.lease = @intCast(allocation.bytes.len);
    const low = stack.start + memory.stacks.layout.guard_bytes;
    const painted_to = nih_sqlite_stack_paint(low);
    report.stack_painted = painted_to;
    var result: Result = .{};
    const rc = if (snapshot) |copy| nih_pqc_snapshot_fixture(allocation.bytes.ptr, allocation.bytes.len, copy.ptr, copy.len, &result) else nih_pqc_arena_fixture(allocation.bytes.ptr, allocation.bytes.len, &result);
    const status = asm volatile ("csrr %[out], mstatus"
        : [out] "=r" (-> u32),
    );
    report.mie = status & 8;
    var first = low;
    while (first < painted_to) : (first += 4) {
        const word: *const volatile u32 = @ptrFromInt(first);
        if (word.* != 0x5a7ec319) break;
    }
    report.stack_used = stack.end - first;
    report.peak = result.peak;
    report.allocs = result.allocs;
    report.frees = result.frees;
    report.failures = result.failures;
    report.live = result.live;
    report.valid = result.valid;
    report.rejected = result.rejected;
    report.oom = result.oom;
    report.verify_ticks = result.verify_ticks;
    report.verify_worker0 = result.verify_worker0;
    report.verify_worker1 = result.verify_worker1;
    std.crypto.secureZero(u8, allocation.bytes);
    report.erased = @intFromBool(std.mem.allEqual(u8, allocation.bytes, 0));
    if (retain) {
        report.status = if (rc == 0 and first > low and report.mie == 8 and report.erased == 1) 1 else 4;
        return report;
    }
    memory.freeExternal(allocation) catch {
        report.status = 3;
        return report;
    };
    report.released = 1;
    report.status = if (rc == 0 and first > low and report.mie == 8 and report.erased == 1) 1 else 4;
    return report;
}
