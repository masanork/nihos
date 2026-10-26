const std = @import("std");
const buddy = @import("buddy_heap.zig");
const resources = @import("task_resources.zig");
const Table = resources.Resources(buddy, 2, 2);
const key = resources.Key{ .slot = 0, .generation = 1 };

test "many small pool children consume one parent entry and copied handles share a cursor" {
    var memory: [4096]u8 align(64) = undefined;
    var heap = buddy.Heap.init(&memory, 0).?;
    var table = Table{};
    try std.testing.expect(table.open(key));
    const pool = try table.openPool(&heap, 0, key, 512, 64);
    const copy = pool;
    const before = heap.free_bytes;
    var end: usize = @intFromPtr(pool.allocation.bytes.ptr);
    for (0..40) |index| {
        const child = try table.allocPool(0, key, if (index % 2 == 0) pool else copy, 7, 4);
        try std.testing.expect(@intFromPtr(child.ptr) >= end);
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(child.ptr) % 4);
        end = @intFromPtr(child.ptr) + child.len;
        @memset(child, @intCast(index));
    }
    try std.testing.expectEqual(before, heap.free_bytes);
    try std.testing.expectEqual(@as(u32, 1), heap.allocations);
    try std.testing.expectEqual(@as(u32, 1), table.owned());
    _ = try table.alloc(&heap, 0, key, 32, 8);
    try std.testing.expectError(error.Full, table.openPool(&heap, 0, key, 32, 8));
    try std.testing.expect(table.close(key));
    try std.testing.expect(!try table.drainOne(&heap, 0, key));
    try std.testing.expect(try table.drainOne(&heap, 0, key));
    try std.testing.expectEqual(@as(u32, 2), table.reclaimed);
    try std.testing.expectEqual(heap.payload.len, heap.free_bytes);
}

test "pool alignment padding exhaustion and invalid requests preserve the cursor" {
    var memory: [4096]u8 align(64) = undefined;
    var heap = buddy.Heap.init(&memory, 0).?;
    var table = Table{};
    try std.testing.expect(table.open(key));
    const pool = try table.openPool(&heap, 0, key, 128, 64);
    _ = try table.allocPool(0, key, pool, 1, 1);
    try std.testing.expectError(error.OutOfMemory, table.allocPool(0, key, pool, 65, 64));
    try std.testing.expectError(error.OutOfMemory, table.allocPool(0, key, pool, std.math.maxInt(usize), 1));
    for ([_][2]usize{ .{ 0, 1 }, .{ 1, 0 }, .{ 1, 3 }, .{ 1, std.math.maxInt(usize) } }) |request| {
        try std.testing.expectError(error.InvalidRequest, table.allocPool(0, key, pool, request[0], request[1]));
    }
    const rest = try table.allocPool(0, key, pool, 127, 1);
    try std.testing.expectEqual(@intFromPtr(pool.allocation.bytes.ptr) + 1, @intFromPtr(rest.ptr));
    try std.testing.expectError(error.OutOfMemory, table.allocPool(0, key, pool, 1, 1));
    try table.closePool(&heap, 0, key, pool);
    try std.testing.expectEqual(heap.payload.len, heap.free_bytes);
}

test "pool operations reject foreign tasks owners and forged parent handles" {
    var memory: [4096]u8 align(64) = undefined;
    var heap = buddy.Heap.init(&memory, 0).?;
    var table = Table{};
    const other = resources.Key{ .slot = 1, .generation = 1 };
    try std.testing.expect(table.open(key) and table.open(other));
    const pool = try table.openPool(&heap, 0, key, 128, 8);
    const before = heap.free_bytes;
    try std.testing.expectError(error.WrongOwner, table.allocPool(1, key, pool, 1, 1));
    try std.testing.expectError(error.WrongOwner, table.closePool(&heap, 1, key, pool));
    try std.testing.expectError(error.Inactive, table.allocPool(0, other, pool, 1, 1));
    try std.testing.expectError(error.Inactive, table.closePool(&heap, 0, other, pool));
    for (0..4) |field| {
        var forged = pool;
        switch (field) {
            0 => forged.allocation.bytes = pool.allocation.bytes[1..],
            1 => forged.allocation.ticket += 1,
            2 => forged.allocation.node += 1,
            else => forged.key = other,
        }
        try std.testing.expectError(error.InvalidAllocation, table.allocPool(0, forged.key, forged, 1, 1));
        try std.testing.expectError(error.InvalidAllocation, table.closePool(&heap, 0, forged.key, forged));
    }
    try std.testing.expectEqual(before, heap.free_bytes);
    const first = try table.allocPool(0, key, pool, 128, 1);
    try std.testing.expectEqual(pool.allocation.bytes.ptr, first.ptr);
}

test "a copied pool cannot survive explicit close or parent address reuse" {
    var memory: [4096]u8 align(64) = undefined;
    var heap = buddy.Heap.init(&memory, 0).?;
    var table = Table{};
    try std.testing.expect(table.open(key));
    const old = try table.openPool(&heap, 0, key, 128, 8);
    const copy = old;
    try table.closePool(&heap, 0, key, old);
    try std.testing.expectError(error.InvalidAllocation, table.allocPool(0, key, copy, 1, 1));
    try std.testing.expectError(error.InvalidAllocation, table.closePool(&heap, 0, key, copy));
    const next = try table.openPool(&heap, 0, key, 128, 8);
    try std.testing.expectEqual(old.allocation.bytes.ptr, next.allocation.bytes.ptr);
    try std.testing.expect(old.allocation.ticket != next.allocation.ticket);
    try std.testing.expectError(error.InvalidAllocation, table.allocPool(0, key, copy, 1, 1));
    try std.testing.expectError(error.InvalidAllocation, table.closePool(&heap, 0, key, copy));
    _ = try table.allocPool(0, key, next, 128, 1);
    try table.closePool(&heap, 0, key, next);
    try std.testing.expectEqual(heap.payload.len, heap.free_bytes);
}

test "task close invalidates pools before draining and after generation reuse" {
    var memory: [4096]u8 align(64) = undefined;
    var heap = buddy.Heap.init(&memory, 0).?;
    var table = Table{};
    try std.testing.expect(table.open(key));
    const old = try table.openPool(&heap, 0, key, 128, 8);
    _ = try table.allocPool(0, key, old, 7, 1);
    const before = heap.free_bytes;
    try std.testing.expect(table.close(key));
    try std.testing.expectError(error.Inactive, table.allocPool(0, key, old, 1, 1));
    try std.testing.expectError(error.Inactive, table.closePool(&heap, 0, key, old));
    try std.testing.expectEqual(before, heap.free_bytes);
    try std.testing.expect(try table.drainOne(&heap, 0, key));
    const next_key = resources.Key{ .slot = key.slot, .generation = 2 };
    try std.testing.expect(table.open(next_key));
    const next = try table.openPool(&heap, 0, next_key, 128, 8);
    try std.testing.expectError(error.Inactive, table.allocPool(0, key, old, 1, 1));
    try std.testing.expectError(error.Inactive, table.allocPool(0, next_key, old, 1, 1));
    try std.testing.expectError(error.Inactive, table.closePool(&heap, 0, next_key, old));
    try table.closePool(&heap, 0, next_key, next);
    try std.testing.expectEqual(heap.payload.len, heap.free_bytes);
}

test "raw allocations cannot masquerade as pools and pool parent free invalidates children API" {
    var memory: [4096]u8 align(64) = undefined;
    var heap = buddy.Heap.init(&memory, 0).?;
    var table = Table{};
    try std.testing.expect(table.open(key));
    const raw = try table.alloc(&heap, 0, key, 128, 8);
    const fake = Table.Pool{ .key = key, .allocation = raw };
    try std.testing.expectError(error.InvalidAllocation, table.allocPool(0, key, fake, 1, 1));
    try std.testing.expectError(error.InvalidAllocation, table.closePool(&heap, 0, key, fake));
    try table.free(&heap, 0, key, raw);
    const pool = try table.openPool(&heap, 0, key, 128, 8);
    try table.free(&heap, 0, key, pool.allocation);
    try std.testing.expectError(error.InvalidAllocation, table.allocPool(0, key, pool, 1, 1));
    try std.testing.expectEqual(heap.payload.len, heap.free_bytes);
}

test "failed pool parent acquisition leaves no phantom pool or quota usage" {
    var memory: [4096]u8 align(64) = undefined;
    var heap = buddy.Heap.init(&memory, 0).?;
    var table = Table{};
    try std.testing.expect(table.open(key));
    try std.testing.expectError(error.InvalidRequest, table.openPool(&heap, 0, key, 0, 8));
    try std.testing.expectError(error.OutOfMemory, table.openPool(&heap, 0, key, heap.payload.len - 32, 8));
    try std.testing.expectError(error.WrongOwner, table.openPool(&heap, 1, key, 128, 8));
    try std.testing.expectEqual(@as(u32, 0), table.owned());
    try std.testing.expectEqual(heap.payload.len, heap.free_bytes);
}
