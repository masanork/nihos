//! Host bridge to opt-in bounded extent groups in the real task ledger.
//! All children are canonical kernel-owned handles; no movable live pointers.
const std = @import("std");
const buddy = @import("buddy_heap");
const resources = @import("task_resources");
const Table = resources.ResourcesWithGroups(buddy, 4, 2, 1, 32);
// SAFETY: Read only after initialized, or through optional live group handles.
var heap: buddy.Heap = undefined;
var table: Table = .{};
var group: ?Table.Group = null;
var generation: u16 = 1;
var initialized = false;
var closing = false;
var initial_free: usize = 0;
var peak: usize = 0;
var largest_extent: usize = 0;
var peers: [2]?buddy.Allocation = .{ null, null };
var peer_opened = false;
var peer_charge: usize = 0;

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
export fn nih_graphics_backing_acquire(raw: usize) ?*anyopaque {
    if (!initialized or closing or !table.active(key()) or raw < 65536 or raw & (raw - 1) != 0) return null;
    const fresh = group == null;
    if (fresh) group = table.openGroup(&heap, 0, key()) catch return null;
    const live = group.?;
    const allocation = table.allocExtent(&heap, 0, key(), live, raw - 128, 64) catch {
        if (fresh) {
            table.closeGroup(&heap, 0, key(), live) catch return null;
            group = null;
        }
        return null;
    };
    largest_extent = @max(largest_extent, raw);
    peak = @max(peak, initial_free - heap.free_bytes - peer_charge);
    return @ptrCast(allocation.bytes.ptr);
}
export fn nih_graphics_backing_release(pointer: ?*anyopaque) c_int {
    if (pointer == null) return 0;
    if (!initialized or closing or !table.active(key())) return -1;
    const live = group orelse return -1;
    const allocation = table.extentFromPointer(0, key(), live, @intFromPtr(pointer.?)) catch return -1;
    table.freeExtent(&heap, 0, key(), live, allocation) catch return -1;
    if ((table.extentCount(0, key(), live) catch return -1) == 0) {
        table.closeGroup(&heap, 0, key(), live) catch return -1;
        group = null;
    }
    return 0;
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
export fn nih_graphics_backing_largest_extent() usize {
    return largest_extent;
}
export fn nih_graphics_backing_parents() u32 {
    return @intFromBool(group != null);
}
export fn nih_graphics_backing_loan_count() u32 {
    if (!initialized or group == null) return 0;
    return @intCast(table.extentCount(0, key(), group.?) catch return 0);
}
const control_bytes = @sizeOf(Table) + @sizeOf(@TypeOf(group)) + @sizeOf(buddy.Heap) +
    @sizeOf(@TypeOf(generation)) + 3 * @sizeOf(bool) + 4 * @sizeOf(usize) + @sizeOf(@TypeOf(peers));
export const nih_graphics_backing_control_size: u32 = control_bytes;
export fn nih_graphics_backing_control_bytes() usize {
    return control_bytes;
}
// Bare lifecycle fixture: no HB process state survives this retirement test.
export fn nih_graphics_backing_retire() c_int {
    if (!initialized or closing or !table.close(key())) return -1;
    closing = true;
    var done = false;
    for (0..33) |_| {
        const before = heap.frees;
        done = table.drainOne(&heap, 0, key()) catch return -1;
        if (heap.frees - before > 1) return -1;
        if (done) break;
    }
    if (!done) return -1;
    group = null;
    return 0;
}
export fn nih_graphics_backing_recovered() c_int {
    return @intFromBool(initialized and heap.free_bytes == initial_free and heap.live == 0 and
        heap.guardsValid() and table.owned() == 0);
}
export fn nih_graphics_backing_reopen() c_int {
    if (!closing or !table.cleaned(key()) or !heap.guardsValid() or generation == std.math.maxInt(u16)) return -1;
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
    const before = heap.free_bytes;
    const allocation = table.alloc(&heap, 0, other, length, 64) catch return null;
    peer_charge += before - heap.free_bytes;
    peers[index] = allocation;
    return @ptrCast(allocation.bytes.ptr);
}
export fn nih_graphics_backing_peer_release() c_int {
    var index: usize = peers.len;
    while (index > 0) {
        index -= 1;
        if (peers[index]) |allocation| {
            const before = heap.free_bytes;
            table.free(&heap, 0, .{ .slot = 1, .generation = 1 }, allocation) catch return -1;
            peer_charge -= heap.free_bytes - before;
            peers[index] = null;
            return 0;
        }
    }
    return -1;
}
