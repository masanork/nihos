//! Owner-local boot arenas in internal SRAM and initialized PSRAM.
//! Descriptors stay internal; reusable allocations use a separate handle API.
const std = @import("std");
const core_arena = @import("core_arena");
const CoreArena = core_arena.CoreArena;
pub const reusable = @import("heap.zig");
pub const stacks = @import("stacks.zig");
pub const dma = @import("dma_memory.zig");

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

const Domain = struct {
    owners: [2]Owner,
    prepared: u32 = 0,
    reports: [2]Report = .{ .{}, .{} },
    buffer_bytes: usize,

    noinline fn prepare(self: *Domain, start: usize, length: usize) bool {
        if (currentHart() != 0 or @atomicLoad(u32, &self.prepared, .acquire) != 0) return false;
        const memory: [*]u8 = @ptrFromInt(start);
        const parts = CoreArena.partition(memory[0..length]) orelse return false;
        for (&self.owners, parts) |*owner, part| owner.* = .{ .pool = part };
        @atomicStore(u32, &self.prepared, 1, .release);
        return true;
    }

    /// Only the cursor update masks local interrupts. No cross-core lock.
    noinline fn alloc(self: *Domain, length: usize, alignment: usize) ?[]u8 {
        const hart = currentHart();
        if (hart >= 2 or @atomicLoad(u32, &self.prepared, .acquire) != 1) return null;
        const status = asm volatile ("csrrci %[result], mstatus, 8"
            : [result] "=r" (-> u32),
            :
            : .{ .memory = true });
        defer {
            if (status & 8 != 0) asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
        }
        return self.owners[hart].pool.alloc(hart, length, alignment);
    }

    noinline fn begin(self: *Domain, expected_mie: u32) bool {
        const hart = currentHart();
        if (hart >= 2 or @atomicLoad(u32, &self.prepared, .acquire) != 1 or interruptEnable() != expected_mie) return false;
        const owner = &self.owners[hart];
        if (owner.bootstrap != null) return false;
        const before = owner.pool.remaining();
        if (!@import("native_options").boot_fast) {
            if (self.alloc(0, 1) != null or self.alloc(8, 3) != null or
                self.alloc(std.math.maxInt(usize), 64) != null or owner.pool.remaining() != before) return false;
            owner.rejected = 3;
        }
        owner.bootstrap = self.alloc(64, 64) orelse return false;
        if (interruptEnable() != expected_mie) return false;
        fill(owner.bootstrap.?, hart, 2);
        return true;
    }

    noinline fn probe(self: *Domain, argument: u32) void {
        const hart = currentHart();
        const worker = argument % 4;
        if (hart >= 2 or argument / 4 != hart or worker >= 2) nih_native_task_failed();
        const owner = &self.owners[hart];
        if (owner.buffers[worker] == null) {
            if (interruptEnable() != 8) nih_native_task_failed();
            const bytes = self.alloc(self.buffer_bytes, 64) orelse nih_native_task_failed();
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

    noinline fn finish(self: *Domain) bool {
        const hart = currentHart();
        if (hart >= 2 or @atomicLoad(u32, &self.prepared, .acquire) != 1) return false;
        const owner = &self.owners[hart];
        if (!owner.pool.guardsValid() or owner.rejected != 3 or
            !valid(owner.bootstrap orelse return false, hart, 2)) return false;
        for (owner.buffers, 0..) |buffer, worker| {
            if (owner.checks[worker] < 4 or !valid(buffer orelse return false, hart, @intCast(worker))) return false;
        }
        const capacity = owner.pool.arena.memory.len;
        self.reports[hart] = .{
            .start = @intFromPtr(owner.pool.memory.ptr),
            .end = @intFromPtr(owner.pool.memory.ptr) + owner.pool.memory.len,
            .capacity = capacity,
            .used = capacity - owner.pool.remaining(),
            .free = owner.pool.remaining(),
            .checks0 = owner.checks[0],
            .checks1 = owner.checks[1],
            .rejected = owner.rejected,
        };
        @atomicStore(u32, &self.reports[hart].confirmed, 1, .release);
        return true;
    }

    fn report(self: *const Domain, hart: u32) Report {
        if (@atomicLoad(u32, &self.reports[hart].confirmed, .acquire) != 1) return .{};
        return self.reports[hart];
    }
};

// SAFETY: CPU0 initializes every owner before release-publishing prepared.
var internal = Domain{ .owners = undefined, .buffer_bytes = 192 };
// SAFETY: The same prepared gate excludes access until PSRAM registration.
var external = Domain{ .owners = undefined, .buffer_bytes = 65536 + 192 };

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

pub fn prepare() bool {
    const start = @intFromPtr(&__heap_start);
    const end = @intFromPtr(&__heap_end);
    return start < end and internal.prepare(start, end - start);
}

/// Only a mapped, checked PSRAM tail may be transferred here by CPU0.
/// CPU1 stays in the external boot rendezvous until this completes.
pub fn prepareExternal(start: u32, length: u32) bool {
    if (!@import("external_layout.zig").valid(start, length)) return false;
    return external.prepare(start, length);
}

pub fn alloc(length: usize, alignment: usize) ?[]u8 {
    return internal.alloc(length, alignment);
}

/// Cached CPU memory; owner-local handles, no DMA or isolation promise.
pub fn allocExternal(length: usize, alignment: usize) reusable.Error!reusable.Allocation {
    return reusable.allocTask(length, alignment);
}

pub fn freeExternal(allocation: reusable.Allocation) reusable.Error!void {
    return reusable.freeTask(allocation);
}

pub fn begin() bool {
    return internal.begin(0);
}

pub fn beginExternal() bool {
    return beginExternalMode(0);
}
/// Exclusive boot owner only: CPU0 scheduler/IPI routes must still be disabled.
/// The sole enabled handler rearms display DMA and cannot allocate.
pub fn beginExternalWithDisplayIrq() bool {
    if (currentHart() != 0) return false;
    return beginExternalMode(8);
}
fn beginExternalMode(expected_mie: u32) bool {
    if (@atomicLoad(u32, &external.prepared, .acquire) == 0) {
        if (allocExternal(64, 64)) |_| return false else |err| return err == error.NotReady;
    }
    if (!external.begin(expected_mie)) return false;
    const owner = &external.owners[currentHart()];
    // Retain the two preemptible boot allocations at the end of the arena.
    const span = external.alloc(owner.pool.remaining() - 2 * external.buffer_bytes, 64) orelse return false;
    return if (expected_mie == 8) reusable.prepareWithDisplayIrq(span) else reusable.prepare(span);
}

fn pattern(hart: u32, worker: u32, index: usize) u8 {
    return @as(u8, @truncate(index *% 37 ^ (index >> 8) ^ (index >> 16))) ^ @as(u8, @intCast(0x40 + hart * 4 + worker));
}

noinline fn fill(bytes: []u8, hart: u32, worker: u32) void {
    for (bytes, 0..) |*byte, index| byte.* = pattern(hart, worker, index);
}

pub noinline fn probe(argument: u32) void {
    internal.probe(argument);
    if (@atomicLoad(u32, &external.prepared, .acquire) == 1) {
        external.probe(argument);
        reusable.probe(argument);
    }
}

noinline fn valid(bytes: []const u8, hart: u32, worker: u32) bool {
    const checked: [*]const volatile u8 = bytes.ptr;
    for (0..bytes.len) |index| if (checked[index] != pattern(hart, worker, index)) return false;
    return @intFromPtr(bytes.ptr) % 64 == 0;
}

pub noinline fn finish() bool {
    // Internal completion is the final publication observed by CPU0. It must
    // also cover the slower, full-buffer external verification and report.
    return reusable.finish() and (@atomicLoad(u32, &external.prepared, .acquire) == 0 or external.finish()) and internal.finish();
}

pub fn report(hart: u32) Report {
    return internal.report(hart);
}

pub fn externalReport(hart: u32) Report {
    return external.report(hart);
}
