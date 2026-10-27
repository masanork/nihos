//! Host bridge using unchanged buddy Heap and the native two-entry task ledger.
//! Client quotas are in LazyPool; all backing belongs to one service task.
//! Single-caller experiment; native interrupt/identity integration is absent.
const std = @import("std");
const buddy = @import("buddy_heap");
const resources = @import("task_resources");
const Table = resources.Resources(buddy, 4, 2);
const Parent = struct { allocation: buddy.Allocation, loans: u32 = 0 };
const Loan = struct { bytes: []u8, parent: usize };
const small_raw = 128 * 1024;
const active_raw = 2 * 1024 * 1024;

// SAFETY: Heap/parents are only read after initialization or optional checks.
var heap: buddy.Heap = undefined;
var table: Table = .{};
var parents: [2]?Parent = .{ null, null };
var loans: [64]?Loan = @splat(null);
var generation: u16 = 1;
var initialized = false;
var closing = false;
var initial_free: usize = 0;
var peak: usize = 0;
var peers: [2]?buddy.Allocation = .{ null, null };
var peer_opened = false;

fn key() resources.Key {
    return .{ .slot = 0, .generation = generation };
}

export fn nih_graphics_backing_init(memory: ?[*]u8, length: usize) c_int {
    if (initialized or memory == null) return -1;
    heap = buddy.Heap.init(memory.?[0..length], 0) orelse return -1;
    if (!table.open(key())) return -1;
    initial_free = heap.free_bytes;
    initialized = true;
    return 0;
}

fn gap(parent: usize, length: usize) ?usize {
    const allocation = parents[parent].?.allocation;
    var start: usize = 0;
    for (0..loans.len + 1) |_| {
        if (start > allocation.bytes.len or length > allocation.bytes.len - start) return null;
        var next = start;
        for (loans) |entry| if (entry) |loan| {
            if (loan.parent != parent) continue;
            const at = @intFromPtr(loan.bytes.ptr) - @intFromPtr(allocation.bytes.ptr);
            if (at < start + length and start < at + loan.bytes.len)
                next = @max(next, at + loan.bytes.len);
        };
        if (next == start) return start;
        start = next;
    }
    return null;
}

export fn nih_graphics_backing_acquire(length: usize) ?*anyopaque {
    if (!initialized or closing or !table.active(key()) or length == 0 or length % 65536 != 0) return null;
    var available: ?usize = null;
    for (loans, 0..) |entry, index| if (entry == null) {
        available = index;
        break;
    };
    const index = available orelse return null;
    var chosen: ?usize = null;
    var offset: usize = 0;
    for (parents, 0..) |entry, parent| if (entry != null) {
        if (gap(parent, length)) |at| {
            chosen = parent;
            offset = at;
            break;
        }
    };
    if (chosen == null) {
        // Slot 0 stays small so retained HB process state does not pin 2 MiB.
        // Slot 1 is shared by every client; neither client owns it exclusively.
        const parent: usize = if (parents[0] == null and length <= small_raw - 128) 0 else 1;
        if (parents[parent] != null) return null;
        const raw: usize = if (parent == 0) small_raw else active_raw;
        if (length > raw - 128) return null;
        const allocation = table.alloc(&heap, 0, key(), raw - 128, 64) catch return null;
        parents[parent] = .{ .allocation = allocation };
        chosen = parent;
        peak = @max(peak, initial_free - heap.free_bytes);
    }
    const parent = chosen.?;
    const bytes = parents[parent].?.allocation.bytes[offset..][0..length];
    loans[index] = .{ .bytes = bytes, .parent = parent };
    parents[parent].?.loans += 1;
    return @ptrCast(bytes.ptr);
}

export fn nih_graphics_backing_release(pointer: ?*anyopaque) c_int {
    if (pointer == null) return 0;
    if (!initialized or closing or !table.active(key())) return -1;
    // Never dereference caller pointers; find the canonical loan first.
    for (&loans) |*entry| if (entry.*) |loan| {
        if (@intFromPtr(loan.bytes.ptr) != @intFromPtr(pointer.?)) continue;
        const parent = &parents[loan.parent].?;
        if (parent.loans == 0) return -1;
        if (parent.loans == 1) {
            table.free(&heap, 0, key(), parent.allocation) catch return -1;
            parents[loan.parent] = null;
        } else parent.loans -= 1;
        entry.* = null;
        return 0;
    };
    return -1;
}

export fn nih_graphics_backing_raw_used() usize {
    return if (initialized) initial_free - heap.free_bytes else 0;
}
export fn nih_graphics_backing_raw_peak() usize {
    return peak;
}
export fn nih_graphics_backing_initial_free() usize {
    return initial_free;
}
export fn nih_graphics_backing_largest_free() usize {
    return if (initialized) heap.largestBlock() else 0;
}
export fn nih_graphics_backing_parents() u32 {
    var count: u32 = 0;
    for (parents) |parent| if (parent != null) {
        count += 1;
    };
    return count;
}
export fn nih_graphics_backing_loan_count() u32 {
    var count: u32 = 0;
    for (loans) |loan| if (loan != null) {
        count += 1;
    };
    return count;
}
export fn nih_graphics_backing_control_bytes() usize {
    return control_bytes;
}
const control_bytes = @sizeOf(Table) + @sizeOf(@TypeOf(parents)) + @sizeOf(@TypeOf(loans)) +
    @sizeOf(buddy.Heap) + @sizeOf(@TypeOf(generation)) + 3 * @sizeOf(bool) +
    2 * @sizeOf(usize) + @sizeOf(@TypeOf(peers));
export const nih_graphics_backing_control_size: u32 = control_bytes;

// Separate lifecycle fixture only: no library objects may be used after retire.
// It demonstrates the existing ledger's bounded deferred reclamation, not
// recovery of HB process-global pointers after killing the font service.
export fn nih_graphics_backing_retire() c_int {
    if (!initialized or closing or !table.close(key())) return -1;
    closing = true;
    var done = false;
    for (0..2) |_| {
        done = table.drainOne(&heap, 0, key()) catch return -1;
        if (done) break;
    }
    if (!done) return -1;
    parents = .{ null, null };
    loans = @splat(null);
    return 0;
}
export fn nih_graphics_backing_recovered() c_int {
    return @intFromBool(initialized and heap.free_bytes == initial_free and heap.live == 0 and
        heap.guardsValid() and table.owned() == 0);
}
export fn nih_graphics_backing_reopen() c_int {
    if (!closing or !table.cleaned(key()) or !heap.guardsValid() or
        generation == std.math.maxInt(u16)) return -1;
    generation += 1;
    if (!table.open(key())) return -1;
    closing = false;
    return 0;
}

export fn nih_graphics_backing_peer_allocate(length: usize) ?*anyopaque {
    if (!initialized) return null;
    var available: ?usize = null;
    for (peers, 0..) |entry, index| if (entry == null) {
        available = index;
        break;
    };
    const index = available orelse return null;
    const other = resources.Key{ .slot = 1, .generation = 1 };
    if (!peer_opened) {
        if (!table.open(other)) return null;
        peer_opened = true;
    }
    const allocation = table.alloc(&heap, 0, other, length, 64) catch return null;
    peers[index] = allocation;
    return @ptrCast(allocation.bytes.ptr);
}
export fn nih_graphics_backing_peer_release() c_int {
    var index: usize = peers.len;
    while (index > 0) {
        index -= 1;
        if (peers[index]) |allocation| {
            table.free(&heap, 0, .{ .slot = 1, .generation = 1 }, allocation) catch return -1;
            peers[index] = null;
            return 0;
        }
    }
    return -1;
}
