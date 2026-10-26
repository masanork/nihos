//! CPU0 broker owns page metadata. CPU1 receives boot-published buffers only.
const std = @import("std");
const pages = @import("page_pool");
pub const layout = @import("high_sram_layout.zig");
const A = std.atomic.Value(u32);
const Pool = pages.Pool(4096, 56, 16);
const Large = pages.Pool(4096, 2048, 4);
extern fn nih_native_task_failed() callconv(.c) noreturn;
// SAFETY: init completes both objects before release-publishing phase 1.
var pool: Pool = undefined;
// SAFETY: vmProbe initializes this object before any allocation or inspection.
var large: Large = undefined;
var phase = A.init(0);
var completed = A.init(0);
var counters: [4]u32 = @splat(0);
// SAFETY: ownerExchange initializes all four leases before phase 3 is published.
var grants: [4]pages.Lease = undefined;
pub const Report = struct {
    status: u32 = 0,
    bytes: u32 = layout.tested_bytes,
    passes: u32 = 0,
    reads: u32 = 0,
    writes: u32 = 0,
    peer_reads: u32 = 0,
    peer_writes: u32 = 0,
    owner_reads: u32 = 0,
    heap_bytes: u32 = layout.heap_bytes,
    free_bytes: u32 = 0,
    guards: u32 = layout.guard_bytes,
    rejected: u32 = 0,
    checks0: u32 = 0,
    checks1: u32 = 0,
    checks2: u32 = 0,
    checks3: u32 = 0,
    recovered: u32 = 0,
};
pub const VmReport = struct { status: u32 = 0, start: u32 = 0x48030000, bytes: u32 = 8 * 1024 * 1024, requested4: u32 = 0, charged4: u32 = 0, requested8: u32 = 0, charged8: u32 = 0, reads: u32 = 0, writes: u32 = 0, boundary_ok: u32 = 0, recovered: u32 = 0 };
var report = Report{};
var vm_report = VmReport{};
fn check(ok: bool) void {
    if (!ok) nih_native_task_failed();
}
fn word(address: u32) *volatile u32 {
    return @ptrFromInt(address);
}
fn pattern(address: u32, pass: u32) u32 {
    const value = address ^ 0xa56c_3197;
    return if (pass == 0) value else ~value;
}
fn writeSpan(start: u32, end: u32, pass: u32) void {
    var address = start;
    while (address < end) : (address += 4) word(address).* = pattern(address, pass);
    asm volatile ("fence rw, rw" ::: .{ .memory = true });
}
fn verifySpan(start: u32, end: u32, pass: u32) void {
    var address = start;
    while (address < end) : (address += 4) check(word(address).* == pattern(address, pass));
}
fn spinUntil(value: *A, expected: u32) void {
    const began = asm volatile ("rdcycle %[v]"
        : [v] "=r" (-> u32),
    );
    while (value.load(.acquire) != expected) {
        const now = asm volatile ("rdcycle %[v]"
            : [v] "=r" (-> u32),
        );
        check(now -% began < 1_000_000_000);
    }
}
pub noinline fn init(psram_bytes: u32) bool {
    if (psram_bytes < 16 * 1024 * 1024) return false;
    for (0..2) |pass| {
        for (layout.tested) |span| writeSpan(span.start, span.end, @intCast(pass));
        for (layout.tested) |span| verifySpan(span.start, span.end, @intCast(pass));
        report.reads += layout.tested_bytes / 4;
        report.writes += layout.tested_bytes / 4;
        report.passes += 1;
    }
    const regions = [_]pages.Region{ .{ .memory = @as([*]u8, @ptrFromInt(layout.heaps[0].start))[0 .. layout.heaps[0].end - layout.heaps[0].start] }, .{ .memory = @as([*]u8, @ptrFromInt(layout.heaps[1].start))[0 .. layout.heaps[1].end - layout.heaps[1].start] } };
    pool = Pool.init(&regions) orelse return false;
    const a = pool.alloc(1, 4096, 64) catch return false;
    const b = pool.alloc(2, 3 * 4096, 4096) catch return false;
    const c = pool.alloc(3, 192 * 1024, 64) catch return false;
    if (pool.alloc(4, 4096, 64)) |_| return false else |err| check(err == error.OutOfMemory);
    report.rejected += 1;
    if (pool.free(9, a)) |_| return false else |err| check(err == error.WrongOwner);
    report.rejected += 1;
    pool.free(1, a) catch return false;
    pool.free(2, b) catch return false;
    pool.free(3, c) catch return false;
    const d = pool.alloc(1, 4096, 64) catch return false;
    check(d.bytes.ptr == a.bytes.ptr and d.ticket != a.ticket);
    if (pool.free(1, a)) |_| return false else |err| check(err == error.InvalidLease);
    report.rejected += 1;
    pool.free(1, d) catch return false;
    check(pool.remaining() == layout.heap_bytes);
    vmProbe();
    phase.store(1, .release);
    return true;
}
noinline fn vmProbe() void {
    const start = vm_report.start;
    const before = word(start - 4).*;
    const after = word(start + vm_report.bytes).*;
    large = Large.init(&.{.{ .memory = @as([*]u8, @ptrFromInt(start))[0..vm_report.bytes] }}) orelse nih_native_task_failed();
    for ([_]u32{ 4 * 1024 * 1024, 8 * 1024 * 1024 }, 0..) |length, pass| {
        const lease = large.alloc(1, length, 64) catch nih_native_task_failed();
        check(lease.charged == length);
        writeSpan(start, start + length, @intCast(pass));
        verifySpan(start, start + length, @intCast(pass));
        vm_report.writes += length / 4;
        vm_report.reads += length / 4;
        if (pass == 0) {
            vm_report.requested4 = length;
            vm_report.charged4 = lease.charged;
        } else {
            vm_report.requested8 = length;
            vm_report.charged8 = lease.charged;
        }
        large.free(1, lease) catch nih_native_task_failed();
        check(large.remaining() == vm_report.bytes);
    }
    check(word(start - 4).* == before and word(start + vm_report.bytes).* == after);
    vm_report.boundary_ok = 1;
    vm_report.recovered = 1;
    vm_report.status = 1;
    // No lease survives transfer of this temporary range to the normal heaps.
}
pub noinline fn peer() void {
    spinUntil(&phase, 1);
    for (layout.tested) |span| verifySpan(span.start, span.end, 1);
    for (layout.tested) |span| writeSpan(span.start, span.end, 0);
    phase.store(2, .release);
    spinUntil(&phase, 3);
}
pub noinline fn ownerExchange() void {
    spinUntil(&phase, 2);
    for (layout.tested) |span| verifySpan(span.start, span.end, 0);
    report.peer_reads = layout.tested_bytes / 4;
    report.peer_writes = layout.tested_bytes / 4;
    report.owner_reads = layout.tested_bytes / 4;
    for (layout.guards) |span| writeSpan(span.start, span.end, 1);
    for (&grants, 0..) |*lease, index| {
        lease.* = pool.alloc(@intCast(index + 1), 4096, 64) catch nih_native_task_failed();
        @memset(lease.bytes, @as(u8, @intCast(0x31 + index)));
    }
    phase.store(3, .release);
}
pub fn probe(argument: u32) void {
    const index = argument / 4 * 2 + argument % 4;
    check(index < 4 and phase.load(.acquire) == 3);
    const lease = &grants[index];
    const value: u8 = @intCast(0x31 + index);
    const bytes: [*]volatile u8 = lease.bytes.ptr;
    const position = counters[index] % lease.bytes.len;
    for ([_]usize{ 0, position, lease.bytes.len - 1 }) |offset| check(bytes[offset] == value);
    bytes[position] = value;
    counters[index] +%= 1;
}
pub noinline fn finish(hart: u32) bool {
    for (0..2) |worker| {
        const index = hart * 2 + worker;
        if (counters[index] < 4) return false;
        for (grants[index].bytes) |byte| if (byte != @as(u8, @intCast(0x31 + index))) return false;
    }
    _ = completed.fetchOr(@as(u32, 1) << @intCast(hart), .release);
    if (hart == 0) {
        spinUntil(&completed, 3);
        for (grants, 0..) |lease, index| pool.free(@intCast(index + 1), lease) catch return false;
        for (layout.guards) |span| verifySpan(span.start, span.end, 1);
        if (pool.remaining() != layout.heap_bytes) return false;
        report.free_bytes = pool.remaining();
        report.checks0 = counters[0];
        report.checks1 = counters[1];
        report.checks2 = counters[2];
        report.checks3 = counters[3];
        report.recovered = 1;
        report.status = 1;
    }
    return true;
}
pub fn result() Report {
    return report;
}
pub fn vmResult() VmReport {
    return vm_report;
}
