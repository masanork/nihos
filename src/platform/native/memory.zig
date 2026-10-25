//! Native SRAM ownership. Only the current hart can access its allocator.
//! No external RAM, fallback allocator, free or reset is available here.
const std = @import("std");
const core_arena = @import("core_arena");
const CoreArena = core_arena.CoreArena;

extern var __heap_start: u8;
extern var __heap_end: u8;
extern fn nih_native_task_failed() callconv(.c) noreturn;

const Owner = struct {
    pool: CoreArena align(core_arena.granule),
    bootstrap: ?[]u8 = null,
    buffers: [2]?[]u8 = .{ null, null },
    checks: [2]u32 = .{ 0, 0 },
    rejected: u32 = 0,
};

pub const Report = struct {
    start: u32 = 0,
    end: u32 = 0,
    capacity: u32 = 0,
    used: u32 = 0,
    free: u32 = 0,
    checks0: u32 = 0,
    checks1: u32 = 0,
    rejected: u32 = 0,
    confirmed: u32 = 0,
};

var owners: [2]Owner = undefined;
var prepared: u32 = 0;
var reports: [2]Report = .{ .{}, .{} };

fn currentHart() u32 {
    return asm volatile ("csrr %[result], mhartid"
        : [result] "=r" (-> u32),
    );
}

fn interruptEnable() u32 {
    return asm volatile ("csrr %[result], mstatus"
        : [result] "=r" (-> u32),
    ) & 8;
}

/// Called once on CPU0, before CPU1 release and before either timer starts.
pub fn prepare() bool {
    if (currentHart() != 0 or @atomicLoad(u32, &prepared, .acquire) != 0) return false;
    const start = @intFromPtr(&__heap_start);
    const end = @intFromPtr(&__heap_end);
    if (start >= end) return false;
    const memory: [*]u8 = @ptrFromInt(start);
    const parts = CoreArena.partition(memory[0 .. end - start]) orelse return false;
    for (&owners, parts) |*owner, part| owner.* = .{ .pool = part };
    @atomicStore(u32, &prepared, 1, .release);
    return true;
}

/// The local interrupt mask serializes preemptible tasks on this hart.
/// Never expose another hart's mutable cursor, or hold a cross-core lock.
pub fn alloc(length: usize, alignment: usize) ?[]u8 {
    const hart = currentHart();
    if (hart >= 2 or @atomicLoad(u32, &prepared, .acquire) != 1) return null;
    const status = asm volatile ("csrrci %[result], mstatus, 8"
        : [result] "=r" (-> u32),
        :
        : .{ .memory = true });
    defer {
        if (status & 8 != 0) asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
    }
    return owners[hart].pool.alloc(hart, length, alignment);
}

pub fn begin() bool {
    const hart = currentHart();
    if (hart >= 2 or @atomicLoad(u32, &prepared, .acquire) != 1 or interruptEnable() != 0) return false;
    const owner = &owners[hart];
    if (owner.bootstrap != null) return false;
    const before = owner.pool.remaining();
    if (alloc(0, 1) != null or alloc(8, 3) != null or
        alloc(std.math.maxInt(usize), 64) != null or owner.pool.remaining() != before) return false;
    owner.rejected = 3;
    owner.bootstrap = alloc(64, 64) orelse return false;
    if (interruptEnable() != 0) return false;
    fill(owner.bootstrap.?, hart, 2);
    return true;
}

fn pattern(hart: u32, worker: u32, index: usize) u8 {
    return @as(u8, @truncate(index *% 37)) ^ @as(u8, @intCast(0x40 + hart * 4 + worker));
}

fn fill(bytes: []u8, hart: u32, worker: u32) void {
    for (bytes, 0..) |*byte, index| byte.* = pattern(hart, worker, index);
}

/// Invoked by both preemptible workers, including compiled FP callbacks.
pub fn probe(argument: u32) void {
    const hart = currentHart();
    const worker = argument % 4;
    if (hart >= 2 or argument / 4 != hart or worker >= 2) nih_native_task_failed();
    const owner = &owners[hart];
    if (owner.buffers[worker] == null) {
        if (interruptEnable() != 8) nih_native_task_failed();
        const bytes = alloc(192, 64) orelse nih_native_task_failed();
        if (interruptEnable() != 8) nih_native_task_failed();
        fill(bytes, hart, worker);
        owner.buffers[worker] = bytes;
    }
    const buffer = owner.buffers[worker].?;
    const bytes: [*]const volatile u8 = buffer.ptr;
    const position = owner.checks[worker] % buffer.len;
    for ([_]usize{ 0, position, buffer.len - 1 }) |index| {
        if (bytes[index] != pattern(hart, worker, index)) nih_native_task_failed();
    }
    owner.checks[worker] +%= 1;
}

fn valid(bytes: []const u8, hart: u32, worker: u32) bool {
    const checked: [*]const volatile u8 = bytes.ptr;
    for (0..bytes.len) |index| if (checked[index] != pattern(hart, worker, index)) return false;
    return @intFromPtr(bytes.ptr) % 64 == 0;
}

/// Workers have exited and been reaped before the IPI protocol completes.
pub fn finish() bool {
    const hart = currentHart();
    if (hart >= 2 or @atomicLoad(u32, &prepared, .acquire) != 1) return false;
    const owner = &owners[hart];
    if (!owner.pool.guardsValid() or owner.rejected != 3 or
        !valid(owner.bootstrap orelse return false, hart, 2)) return false;
    for (owner.buffers, 0..) |buffer, worker| {
        if (owner.checks[worker] < 4 or !valid(buffer orelse return false, hart, @intCast(worker))) return false;
    }
    const capacity = owner.pool.arena.memory.len;
    reports[hart] = .{
        .start = @intFromPtr(owner.pool.memory.ptr),
        .end = @intFromPtr(owner.pool.memory.ptr) + owner.pool.memory.len,
        .capacity = capacity,
        .used = capacity - owner.pool.remaining(),
        .free = owner.pool.remaining(),
        .checks0 = owner.checks[0],
        .checks1 = owner.checks[1],
        .rejected = owner.rejected,
    };
    @atomicStore(u32, &reports[hart].confirmed, 1, .release);
    return true;
}

/// A release/acquire publication; mutable allocator state never crosses harts.
pub fn report(hart: u32) Report {
    if (@atomicLoad(u32, &reports[hart].confirmed, .acquire) != 1) return .{};
    return reports[hart];
}
