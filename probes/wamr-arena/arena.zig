//! Single-owner experimental WAMR bridge to nihos's buddy heap.
//! Borrowed fixed backing: no kernel integration, task migration, concurrent callers,
//! physical-memory placement, or stale-pointer detection after address reuse.
const buddy = @import("buddy_heap");
const count = 2;
const max_objects = 128;
const runtime_capacity = 128 * 1024;
const linear_capacity = 256 * 1024;
var heaps: [count]buddy.Heap = undefined;
var objects: [count][max_objects]?buddy.Allocation = @splat(@splat(null));
var ready = false;

/// Caller owns two disjoint 64-aligned regions for the complete adapter lifetime.
/// This trusted interface cannot verify that pointers refer to writable memory.
export fn nih_wamr_arena_init(runtime_ptr: ?[*]u8, runtime_length: usize, linear_ptr: ?[*]u8, linear_length: usize) callconv(.c) c_int {
    if (ready or runtime_length != runtime_capacity or linear_length != linear_capacity) return -1;
    const runtime = runtime_ptr orelse return -1;
    const linear = linear_ptr orelse return -1;
    const a = @intFromPtr(runtime);
    const b = @intFromPtr(linear);
    if (a % 64 != 0 or b % 64 != 0 or (if (a <= b) b - a < runtime_length else a - b < linear_length)) return -1;
    heaps[0] = buddy.Heap.init(runtime[0..runtime_length], 0) orelse return -1;
    heaps[1] = buddy.Heap.init(linear[0..linear_length], 0) orelse return -1;
    objects = @splat(@splat(null));
    ready = true;
    return 0;
}
export fn nih_wamr_arena_alloc(kind: u32, size: usize) callconv(.c) ?*anyopaque {
    if (!ready or kind >= count) return null;
    for (&objects[kind]) |*slot| {
        if (slot.* != null) continue;
        const allocation = heaps[kind].alloc(0, @max(size, 1), 16) catch return null;
        slot.* = allocation;
        return @ptrCast(allocation.bytes.ptr);
    }
    return null;
}
export fn nih_wamr_arena_free(kind: u32, pointer: ?*anyopaque) callconv(.c) c_int {
    if (!ready or kind >= count) return -1;
    const address = @intFromPtr(pointer orelse return 0);
    for (&objects[kind]) |*slot| {
        const allocation = slot.* orelse continue;
        if (@intFromPtr(allocation.bytes.ptr) != address) continue;
        heaps[kind].free(0, allocation) catch return -1;
        slot.* = null;
        return 0;
    }
    return -1;
}
export fn nih_wamr_arena_recovered(kind: u32) callconv(.c) c_int {
    if (!ready or kind >= count) return 0;
    for (objects[kind]) |object| if (object != null) return 0;
    return @intFromBool(!heaps[kind].faulted and heaps[kind].live == 0 and heaps[kind].free_bytes == heaps[kind].payload.len and heaps[kind].guardsValid());
}
export fn nih_wamr_arena_free_bytes(kind: u32) callconv(.c) usize {
    if (!ready or kind >= count) return 0;
    return heaps[kind].free_bytes;
}

test "separate arenas reject wrong owner and recover all blocks" {
    const testing = @import("std").testing;
    const Backing = struct {
        var runtime: [runtime_capacity]u8 align(64) = undefined;
        var linear: [linear_capacity]u8 align(64) = undefined;
    };
    try testing.expectEqual(@as(c_int, -1), nih_wamr_arena_init(null, runtime_capacity, &Backing.linear, linear_capacity));
    try testing.expectEqual(@as(c_int, -1), nih_wamr_arena_init(&Backing.runtime, runtime_capacity, null, linear_capacity));
    try testing.expectEqual(@as(c_int, -1), nih_wamr_arena_init(&Backing.runtime, runtime_capacity, &Backing.runtime, linear_capacity));
    try testing.expectEqual(@as(c_int, -1), nih_wamr_arena_init(@ptrFromInt(@intFromPtr(&Backing.runtime) + 1), runtime_capacity, &Backing.linear, linear_capacity));
    try testing.expectEqual(@as(c_int, -1), nih_wamr_arena_init(&Backing.runtime, runtime_capacity - 1, &Backing.linear, linear_capacity));
    try testing.expectEqual(@as(c_int, -1), nih_wamr_arena_init(&Backing.runtime, runtime_capacity, &Backing.linear, linear_capacity - 1));
    try testing.expectEqual(@as(c_int, 0), nih_wamr_arena_init(&Backing.runtime, runtime_capacity, &Backing.linear, linear_capacity));
    const before0 = nih_wamr_arena_free_bytes(0);
    const before1 = nih_wamr_arena_free_bytes(1);
    const p = nih_wamr_arena_alloc(0, 32).?;
    const q = nih_wamr_arena_alloc(1, 65536).?;
    try testing.expectEqual(@as(c_int, -1), nih_wamr_arena_free(1, p));
    try testing.expectEqual(@as(c_int, -1), nih_wamr_arena_free(0, @ptrFromInt(1)));
    try testing.expect(nih_wamr_arena_alloc(2, 32) == null);
    try testing.expectEqual(@as(c_int, 0), nih_wamr_arena_free(0, p));
    try testing.expectEqual(@as(c_int, -1), nih_wamr_arena_free(0, p));
    try testing.expectEqual(@as(c_int, 0), nih_wamr_arena_free(1, q));
    try testing.expectEqual(before0, nih_wamr_arena_free_bytes(0));
    try testing.expectEqual(before1, nih_wamr_arena_free_bytes(1));
    try testing.expectEqual(@as(c_int, 1), nih_wamr_arena_recovered(0));
    try testing.expectEqual(@as(c_int, 1), nih_wamr_arena_recovered(1));
    try testing.expect(nih_wamr_arena_alloc(0, @import("std").math.maxInt(usize)) == null);
    var allocated: [max_objects]?*anyopaque = @splat(null);
    for (&allocated) |*item| item.* = nih_wamr_arena_alloc(0, 1) orelse return error.UnexpectedOutOfMemory;
    try testing.expect(nih_wamr_arena_alloc(0, 1) == null);
    for (allocated) |item| try testing.expectEqual(@as(c_int, 0), nih_wamr_arena_free(0, item));
    try testing.expectEqual(@as(c_int, 1), nih_wamr_arena_recovered(0));
}
