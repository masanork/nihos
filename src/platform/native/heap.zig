//! Per-hart reusable PSRAM heaps; descriptor state stays in internal SRAM.
const std = @import("std");
const buddy = @import("buddy_heap");
const task_resources = @import("task_resources");
pub const Key = task_resources.Key;
const Ledger = task_resources.Resources(buddy, 4, 2);
pub const Allocation = buddy.Allocation;
pub const Pool = Ledger.Pool;
pub const Slab = Ledger.Slab;
pub const Cell = task_resources.slab.Allocation;
pub const Error = Ledger.Error || error{ NotReady, InterruptsDisabled };
extern fn nih_native_task_failed() callconv(.c) noreturn;

const Owner = struct {
    heap: buddy.Heap align(64),
    workers: [2]?Allocation = .{ null, null },
    checks: [2]u32 = .{ 0, 0 },
    rejected: u32 = 0,
};
pub const Report = struct {
    start: u32 = 0,
    end: u32 = 0,
    metadata: u32 = 0,
    capacity: u32 = 0,
    free: u32 = 0,
    live: u32 = 0,
    allocations: u32 = 0,
    frees: u32 = 0,
    rejected: u32 = 0,
    checks0: u32 = 0,
    checks1: u32 = 0,
    levels: u32 = 0,
    max_steps: u32 = 0,
    confirmed: u32 = 0,
};

// SAFETY: Each hart initializes its descriptor before publishing prepared.
var owners: [2]Owner align(64) = undefined;
var prepared: [2]u32 = .{ 0, 0 };
var reports: [2]Report = .{ .{}, .{} };

const Resources = struct {
    ledger: Ledger align(64) = .{},
    current: Key = .{ .slot = 0, .generation = 0 },
    stale: u32 = 0,
    full: u32 = 0,
    forced: u32 = 0,
    pool_objects: u32 = 0,
    pool_rejected: u32 = 0,
    slab_objects: u32 = 0,
    slab_frees: u32 = 0,
    slab_rejected: u32 = 0,
};
var resources: [2]Resources = .{ .{}, .{} };
pub const ResourceReport = struct {
    opened: u32 = 0,
    closed: u32 = 0,
    completed: u32 = 0,
    reclaimed: u32 = 0,
    reuses: u32 = 0,
    owned: u32 = 0,
    pending: u32 = 0,
    stale: u32 = 0,
    full: u32 = 0,
    forced: u32 = 0,
    pool_objects: u32 = 0,
    pool_rejected: u32 = 0,
    slab_objects: u32 = 0,
    slab_frees: u32 = 0,
    slab_rejected: u32 = 0,
};

/// Trap-side operations touch only the fixed internal ledger, never PSRAM.
pub fn openTask(core: u32, key: Key) bool {
    const state = &resources[core];
    if (!state.ledger.open(key)) return false;
    if (key.generation > 1) {
        const old = Key{ .slot = key.slot, .generation = key.generation - 1 };
        if (state.ledger.close(old) or state.ledger.active(old)) return false;
        state.stale += 1;
    }
    return true;
}

pub fn selectTask(core: u32, key: Key) void {
    resources[core].current = key;
}

pub fn closeTask(core: u32, key: Key) bool {
    return resources[core].ledger.close(key);
}

pub fn taskCleaned(core: u32, key: Key) bool {
    return resources[core].ledger.cleaned(key);
}

pub fn terminatedTask(core: u32) void {
    resources[core].forced += 1;
}

fn mask() u32 {
    return asm volatile ("csrrci %[result], mstatus, 8"
        : [result] "=r" (-> u32),
        :
        : .{ .memory = true });
}

fn restore(status: u32) void {
    if (status & 8 != 0) asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
}

pub noinline fn allocTask(length: usize, alignment: usize) Error!Allocation {
    const core = hart();
    if (core >= 2 or @atomicLoad(u32, &prepared[core], .acquire) != 1) return error.NotReady;
    const status = mask();
    defer restore(status);
    return resources[core].ledger.alloc(&owners[core].heap, core, resources[core].current, length, alignment);
}

pub noinline fn freeTask(allocation: Allocation) Error!void {
    const core = hart();
    if (core >= 2 or @atomicLoad(u32, &prepared[core], .acquire) != 1) return error.NotReady;
    const status = mask();
    defer restore(status);
    return resources[core].ledger.free(&owners[core].heap, core, resources[core].current, allocation);
}

pub noinline fn openPool(length: usize, alignment: usize) Error!Pool {
    const core = hart();
    if (core >= 2 or @atomicLoad(u32, &prepared[core], .acquire) != 1) return error.NotReady;
    const status = mask();
    defer restore(status);
    return resources[core].ledger.openPool(&owners[core].heap, core, resources[core].current, length, alignment);
}

pub noinline fn allocPool(pool: Pool, length: usize, alignment: usize) Error![]u8 {
    const core = hart();
    if (core >= 2 or @atomicLoad(u32, &prepared[core], .acquire) != 1) return error.NotReady;
    const status = mask();
    defer restore(status);
    return resources[core].ledger.allocPool(core, resources[core].current, pool, length, alignment);
}

pub noinline fn closePool(pool: Pool) Error!void {
    const core = hart();
    if (core >= 2 or @atomicLoad(u32, &prepared[core], .acquire) != 1) return error.NotReady;
    const status = mask();
    defer restore(status);
    return resources[core].ledger.closePool(&owners[core].heap, core, resources[core].current, pool);
}

/// Parent registration and publication are bounded masked operations;
/// linear cell initialization runs between them with interrupts enabled.
pub noinline fn openSlab(object_bytes: usize, count: usize) Error!Slab {
    const core = hart();
    if (core >= 2 or @atomicLoad(u32, &prepared[core], .acquire) != 1) return error.NotReady;
    if (interrupts() == 0) return error.InterruptsDisabled;
    const pending = blk: {
        const status = mask();
        defer restore(status);
        const state = &resources[core];
        const lease = try state.ledger.reserveSlab(&owners[core].heap, core, state.current, object_bytes, count);
        const view = state.ledger.prepareSlab(core, state.current, lease) catch |err| {
            try closeSlab(lease);
            return err;
        };
        break :blk .{ .lease = lease, .view = view };
    };
    pending.view.initialize();
    const status = mask();
    defer restore(status);
    resources[core].ledger.publishSlab(core, resources[core].current, pending.lease) catch |err| {
        try closeSlab(pending.lease);
        return err;
    };
    return pending.lease;
}

pub noinline fn allocSlab(lease: Slab) Error!Cell {
    const core = hart();
    if (core >= 2 or @atomicLoad(u32, &prepared[core], .acquire) != 1) return error.NotReady;
    const status = mask();
    defer restore(status);
    return resources[core].ledger.allocSlab(core, resources[core].current, lease);
}

pub noinline fn freeSlab(lease: Slab, cell: Cell) Error!void {
    const core = hart();
    if (core >= 2 or @atomicLoad(u32, &prepared[core], .acquire) != 1) return error.NotReady;
    const status = mask();
    defer restore(status);
    return resources[core].ledger.freeSlab(core, resources[core].current, lease, cell);
}

pub noinline fn closeSlab(lease: Slab) Error!void {
    const core = hart();
    if (core >= 2 or @atomicLoad(u32, &prepared[core], .acquire) != 1) return error.NotReady;
    const status = mask();
    defer restore(status);
    return resources[core].ledger.closeSlab(&owners[core].heap, core, resources[core].current, lease);
}

noinline fn fillSlabCell(bytes: []u8, expected: u8) void {
    @memset(bytes, expected);
}

noinline fn validSlabCell(bytes: []u8, expected: u8) bool {
    const source: [*]const volatile u8 = bytes.ptr;
    for (0..bytes.len) |index| if (source[index] != expected) return false;
    return true;
}

noinline fn slabProbe(lease: Slab) Cell {
    const core = hart();
    // SAFETY: The tested prefix is filled before reads; replacements stay inside it.
    var cells: [16]Cell = undefined;
    const metadata = task_resources.slab;
    if (lease.allocation.bytes.len < metadata.header_bytes + 8 * (metadata.cell_metadata_bytes + 32)) nih_native_task_failed();
    const count = @min(cells.len, (lease.allocation.bytes.len - metadata.header_bytes) / (metadata.cell_metadata_bytes + 32));
    const copy = lease;
    for (cells[0..count], 0..) |*cell, index| {
        cell.* = allocSlab(copy) catch nih_native_task_failed();
        if (cell.index != index or cell.bytes.len != 32 or interrupts() != 8) nih_native_task_failed();
    }
    if (allocSlab(lease)) |_| nih_native_task_failed() else |err| {
        if (err != error.OutOfMemory or interrupts() != 8) nih_native_task_failed();
        resources[core].slab_rejected += 1;
    }
    const stale = cells[0];
    for (0..4) |index| freeSlab(lease, cells[index * 2]) catch nih_native_task_failed();
    if (freeSlab(lease, stale)) |_| nih_native_task_failed() else |err| {
        if (err != error.InvalidAllocation or interrupts() != 8) nih_native_task_failed();
        resources[core].slab_rejected += 1;
    }
    for (0..4) |_| {
        const cell = allocSlab(lease) catch nih_native_task_failed();
        if (cell.index >= count or interrupts() != 8) nih_native_task_failed();
        cells[cell.index] = cell;
    }
    if (freeSlab(lease, stale)) |_| nih_native_task_failed() else |err| {
        if (err != error.InvalidAllocation or interrupts() != 8) nih_native_task_failed();
        resources[core].slab_rejected += 1;
    }
    for (cells[0..count], 0..) |cell, index| fillSlabCell(cell.bytes, @intCast(0x40 + index));
    for (cells[0..count], 0..) |cell, index| if (!validSlabCell(cell.bytes, @intCast(0x40 + index))) nih_native_task_failed();
    resources[core].slab_objects += @intCast(count + 4);
    resources[core].slab_frees += 4;
    return cells[0];
}

noinline fn poolProbe(pool: Pool) void {
    const copy = pool;
    const first = allocPool(pool, 7, 1) catch nih_native_task_failed();
    const second = allocPool(copy, 33, 32) catch nih_native_task_failed();
    const third = allocPool(pool, 11, 8) catch nih_native_task_failed();
    if (interrupts() != 8 or @intFromPtr(second.ptr) % 32 != 0 or @intFromPtr(third.ptr) % 8 != 0 or
        @intFromPtr(first.ptr) + first.len > @intFromPtr(second.ptr) or
        @intFromPtr(second.ptr) + second.len > @intFromPtr(third.ptr)) nih_native_task_failed();
    @memset(first, 0x15);
    @memset(second, 0x26);
    @memset(third, 0x37);
    for ([_][]u8{ first, second, third }, [_]u8{ 0x15, 0x26, 0x37 }) |child, expected| {
        const bytes: [*]const volatile u8 = child.ptr;
        for (0..child.len) |index| if (bytes[index] != expected) nih_native_task_failed();
    }
    resources[hart()].pool_objects += 3;
}

/// Fixture tasks retain a monotonic pool and a slab at exit/termination.
pub noinline fn lifecycleProbe() void {
    const core = hart();
    if (@atomicLoad(u32, &prepared[core], .acquire) == 0) return;
    const disabled = mask();
    const refused = openSlab(32, 16);
    restore(disabled);
    if (refused) |_| nih_native_task_failed() else |err| {
        if (err != error.InterruptsDisabled or interrupts() != 8) nih_native_task_failed();
        resources[core].slab_rejected += 1;
    }
    const a = openPool(256, 64) catch nih_native_task_failed();
    poolProbe(a);
    const slab = openSlab(32, 16) catch nih_native_task_failed();
    const old_cell = slabProbe(slab);
    if (allocTask(8, 8)) |_| nih_native_task_failed() else |err| {
        if (err != error.Full or interrupts() != 8) nih_native_task_failed();
        resources[core].full += 1; // Only the serialized lifecycle task writes.
    }
    closeSlab(slab) catch nih_native_task_failed();
    const next_slab = openSlab(32, 16) catch nih_native_task_failed();
    if (allocSlab(slab)) |_| nih_native_task_failed() else |err| {
        if (err != error.InvalidAllocation or interrupts() != 8) nih_native_task_failed();
        resources[core].slab_rejected += 1;
    }
    _ = slabProbe(next_slab);
    if (freeSlab(next_slab, old_cell)) |_| nih_native_task_failed() else |err| {
        if (err != error.InvalidAllocation or interrupts() != 8) nih_native_task_failed();
        resources[core].slab_rejected += 1;
    }
    if (allocPool(a, 256, 1)) |_| nih_native_task_failed() else |err| {
        if (err != error.OutOfMemory or interrupts() != 8) nih_native_task_failed();
        resources[core].pool_rejected += 1;
    }
    closePool(a) catch nih_native_task_failed();
    const replacement = openPool(256, 64) catch nih_native_task_failed();
    if (allocPool(a, 1, 1)) |_| nih_native_task_failed() else |err| {
        if (err != error.InvalidAllocation or interrupts() != 8) nih_native_task_failed();
        resources[core].pool_rejected += 1;
    }
    poolProbe(replacement);
}

/// Bootstrap-only. At most one handle is released per call; a completed
/// close asks the scheduler to revisit its retained completion record.
pub noinline fn cleanupOne() enum { none, progress, complete } {
    const core = hart();
    const before = mask();
    const next = resources[core].ledger.pending();
    restore(before);
    const pending = next orelse return .none;
    var worker: ?usize = null;
    if (pending.allocation) |allocation| {
        for (owners[core].workers, 0..) |entry, index| if (entry) |candidate| {
            if (Ledger.equal(candidate, allocation)) {
                if (!valid(allocation, core, @intCast(index))) nih_native_task_failed();
                worker = index;
                break;
            }
        };
    }
    const status = mask();
    defer restore(status);
    const complete = if (pending.allocation == null)
        resources[core].ledger.finishEmpty(pending.key) catch nih_native_task_failed()
    else
        resources[core].ledger.drainOne(&owners[core].heap, core, pending.key) catch nih_native_task_failed();
    if (worker) |index| owners[core].workers[index] = null;
    return if (complete) .complete else .progress;
}

pub fn resourceReport(core: u32) ResourceReport {
    const ledger = &resources[core].ledger;
    return .{ .opened = ledger.opened, .closed = ledger.closed, .completed = ledger.completed, .reclaimed = ledger.reclaimed, .reuses = ledger.reuses, .owned = ledger.owned(), .pending = @intFromBool(ledger.pending() != null), .stale = resources[core].stale, .full = resources[core].full, .forced = resources[core].forced, .pool_objects = resources[core].pool_objects, .pool_rejected = resources[core].pool_rejected, .slab_objects = resources[core].slab_objects, .slab_frees = resources[core].slab_frees, .slab_rejected = resources[core].slab_rejected };
}

fn hart() u32 {
    return asm volatile ("csrr %[result], mhartid"
        : [result] "=r" (-> u32),
    );
}

fn interrupts() u32 {
    return asm volatile ("csrr %[result], mstatus"
        : [result] "=r" (-> u32),
    ) & 8;
}

noinline fn alloc(length: usize, alignment: usize) Error!Allocation {
    const core = hart();
    if (core >= 2 or @atomicLoad(u32, &prepared[core], .acquire) != 1) return error.NotReady;
    const status = asm volatile ("csrrci %[result], mstatus, 8"
        : [result] "=r" (-> u32),
        :
        : .{ .memory = true });
    defer if (status & 8 != 0) asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
    return owners[core].heap.alloc(core, length, alignment);
}

noinline fn free(allocation: Allocation) Error!void {
    const core = hart();
    if (core >= 2 or @atomicLoad(u32, &prepared[core], .acquire) != 1) return error.NotReady;
    const status = asm volatile ("csrrci %[result], mstatus, 8"
        : [result] "=r" (-> u32),
        :
        : .{ .memory = true });
    defer if (status & 8 != 0) asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
    return owners[core].heap.free(core, allocation);
}

fn rejectFree(owner: *Owner, allocation: Allocation, expected: Error) bool {
    free(allocation) catch |err| {
        if (err != expected or interrupts() != 0) return false;
        _ = @atomicRmw(u32, &owner.rejected, .Add, 1, .monotonic);
        return true;
    };
    return false;
}

/// Boot-only initialization; the other hart waits before either timer starts.
pub noinline fn prepare(memory: []u8) bool {
    const core = hart();
    if (core >= 2 or interrupts() != 0 or @atomicLoad(u32, &prepared[core], .acquire) != 0) return false;
    owners[core] = .{ .heap = buddy.Heap.init(memory, core) orelse return false };
    @atomicStore(u32, &prepared[core], 1, .release);
    const owner = &owners[core];
    for ([_][2]usize{ .{ 0, 1 }, .{ 8, 3 }, .{ std.math.maxInt(usize), 64 } }) |request| {
        if (alloc(request[0], request[1])) |_| return false else |err| {
            if (err != error.InvalidRequest or interrupts() != 0) return false;
            _ = @atomicRmw(u32, &owner.rejected, .Add, 1, .monotonic);
        }
    }
    const old = alloc(32, 8) catch return false;
    free(old) catch return false;
    if (!rejectFree(owner, old, error.InvalidAllocation)) return false;
    const next = alloc(32, 8) catch return false;
    if (next.bytes.ptr != old.bytes.ptr or next.ticket == old.ticket or
        !rejectFree(owner, old, error.InvalidAllocation)) return false;
    var bad = next;
    bad.bytes = next.bytes[1..];
    if (!rejectFree(owner, bad, error.InvalidAllocation)) return false;
    bad = next;
    bad.bytes = next.bytes[0..31];
    if (!rejectFree(owner, bad, error.InvalidAllocation)) return false;
    bad = next;
    bad.owner ^= 1;
    if (!rejectFree(owner, bad, error.WrongOwner)) return false;
    free(next) catch return false;
    return interrupts() == 0 and owner.heap.free_bytes == owner.heap.payload.len;
}

fn pattern(core: u32, worker: u32, index: usize) u8 {
    return @as(u8, @truncate(index *% 19 ^ index >> 8)) ^ @as(u8, @intCast(0x70 + core * 4 + worker));
}

fn valid(allocation: Allocation, core: u32, worker: u32) bool {
    const bytes: [*]const volatile u8 = allocation.bytes.ptr;
    for (0..allocation.bytes.len) |index| if (bytes[index] != pattern(core, worker, index)) return false;
    return true;
}

pub noinline fn probe(argument: u32) void {
    const core = hart();
    if (core >= 2 or @atomicLoad(u32, &prepared[core], .acquire) != 1 or argument / 4 != core) nih_native_task_failed();
    const worker = argument % 4;
    if (worker >= 2) nih_native_task_failed();
    const owner = &owners[core];
    if (owner.checks[worker] == 0) {
        if (alloc(0, 1)) |_| nih_native_task_failed() else |err| {
            if (err != error.InvalidRequest or interrupts() != 8) nih_native_task_failed();
            _ = @atomicRmw(u32, &owner.rejected, .Add, 1, .monotonic);
        }
        const temporary = alloc(8, 8) catch nih_native_task_failed();
        free(temporary) catch nih_native_task_failed();
        if (free(temporary)) |_| nih_native_task_failed() else |err| {
            if (err != error.InvalidAllocation or interrupts() != 8) nih_native_task_failed();
            _ = @atomicRmw(u32, &owner.rejected, .Add, 1, .monotonic);
        }
    }
    if (owner.checks[worker] % 64 == 0) {
        if (owner.workers[worker]) |previous| {
            if (!valid(previous, core, worker)) nih_native_task_failed();
            freeTask(previous) catch nih_native_task_failed();
        }
        const length = 1 + (owner.checks[worker] *% 13 + worker * 97) % 2048;
        const alignment: usize = if (owner.checks[worker] & 64 == 0) 64 else 256;
        const allocation = allocTask(length, alignment) catch nih_native_task_failed();
        if (interrupts() != 8 or @intFromPtr(allocation.bytes.ptr) % alignment != 0) nih_native_task_failed();
        for (allocation.bytes, 0..) |*byte, index| byte.* = pattern(core, worker, index);
        owner.workers[worker] = allocation;
    }
    const allocation = owner.workers[worker] orelse nih_native_task_failed();
    const bytes: [*]const volatile u8 = allocation.bytes.ptr;
    const position = owner.checks[worker] % allocation.bytes.len;
    if (bytes[position] != pattern(core, worker, position)) nih_native_task_failed();
    owner.checks[worker] +%= 1;
}

pub noinline fn finish() bool {
    const core = hart();
    if (core >= 2) return false;
    if (@atomicLoad(u32, &prepared[core], .acquire) == 0) return true;
    const owner = &owners[core];
    for (owner.workers, 0..) |entry, worker| {
        if (entry != null or owner.checks[worker] < 4) return false;
    }
    if (owner.heap.free_bytes != owner.heap.payload.len or owner.heap.live != 0) return false;
    // Greedy maximal blocks exhaust the initial forest in at most levels+1
    // operations. No array or loop scales with the number of minimum blocks.
    var allocations: [32]Allocation = undefined;
    var count: usize = 0;
    while (owner.heap.largestBlock() != 0) {
        if (count >= allocations.len) return false;
        allocations[count] = alloc(owner.heap.largestBlock() - buddy.header_bytes - 7, 8) catch return false;
        count += 1;
    }
    if (alloc(8, 8)) |_| return false else |err| {
        if (err != error.OutOfMemory or owner.heap.free_bytes != 0) return false;
        _ = @atomicRmw(u32, &owner.rejected, .Add, 1, .monotonic);
    }
    while (count != 0) {
        count -= 1;
        free(allocations[count]) catch return false;
    }
    if (!owner.heap.guardsValid() or owner.heap.free_bytes != owner.heap.payload.len or owner.heap.live != 0 or
        owner.heap.allocations != owner.heap.frees or owner.rejected != 13) return false;
    const heap = &owner.heap;
    reports[core] = .{
        .start = @intFromPtr(heap.memory.ptr),
        .end = @intFromPtr(heap.memory.ptr) + heap.memory.len,
        .metadata = heap.tree.len,
        .capacity = heap.payload.len,
        .free = heap.free_bytes,
        .live = heap.live,
        .allocations = heap.allocations,
        .frees = heap.frees,
        .rejected = owner.rejected,
        .checks0 = owner.checks[0],
        .checks1 = owner.checks[1],
        .levels = heap.levels,
        .max_steps = heap.max_steps,
    };
    @atomicStore(u32, &reports[core].confirmed, 1, .release);
    return true;
}

pub fn report(core: u32) Report {
    if (@atomicLoad(u32, &reports[core].confirmed, .acquire) != 1) return .{};
    return reports[core];
}
