const std = @import("std");
const slab = @import("slab.zig");
const buddy = @import("buddy_heap.zig");
const resources = @import("task_resources.zig");
const Table = resources.Resources(buddy, 2, 2);
const key = resources.Key{ .slot = 0, .generation = 1 };

fn ready(table: *Table, heap: *buddy.Heap, owner: resources.Key, size: usize, count: usize) !Table.Slab {
    const lease = try table.reserveSlab(heap, 0, owner, size, count);
    const view = try table.prepareSlab(0, owner, lease);
    view.initialize();
    try table.publishSlab(0, owner, lease);
    return lease;
}

test "slab geometry rejects invalid size count alignment and partial spans" {
    var memory: [512]u8 align(8) = undefined;
    for ([_][2]usize{ .{ 0, 1 }, .{ 65537, 1 }, .{ 8, 0 }, .{ 8, slab.max_cells + 1 } }) |request| {
        try std.testing.expect(slab.requiredBytes(request[0], request[1]) == null);
    }
    try std.testing.expectEqual(@as(usize, 32), slab.header_bytes);
    try std.testing.expectEqual(@as(usize, 16), slab.cell_metadata_bytes);
    try std.testing.expect(slab.View.from(memory[1..225], 32, 1) == null);
    try std.testing.expect(slab.View.from(memory[0..223], 32, 1) == null);
    try std.testing.expect(slab.View.from(memory[0..32], 32, 1) == null);
    try std.testing.expect(slab.View.from(memory[0..224], 32, 0) == null);
}

test "cell alignment capacity copied views and payload separation across sizes" {
    for ([_]usize{ 1, 7, 8, 9, 31, 32, 127 }) |size| {
        var memory: [512]u8 align(8) = @splat(0xa5);
        const length = slab.requiredBytes(size, 3).?;
        const view = slab.View.from(memory[0..length], size, 1).?;
        view.initialize();
        const copy = view;
        var cells: [3]slab.Allocation = undefined;
        for (&cells, 0..) |*cell, index| {
            cell.* = try copy.alloc();
            try std.testing.expectEqual(@as(u32, @intCast(index)), cell.index);
            try std.testing.expectEqual(size, cell.bytes.len);
            try std.testing.expectEqual(@as(usize, 0), @intFromPtr(cell.bytes.ptr) % 8);
            for (cell.bytes) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
            @memset(cell.bytes, @intCast(index));
        }
        try std.testing.expectError(error.OutOfMemory, view.alloc());
        for (cells, 0..) |cell, index| {
            for (cell.bytes) |byte| try std.testing.expectEqual(@as(u8, @intCast(index)), byte);
            try view.free(cell);
        }
        const next = try copy.alloc();
        try std.testing.expectEqual(cells[2].bytes.ptr, next.bytes.ptr);
        try std.testing.expect(next.ticket != cells[2].ticket);
        try std.testing.expectError(error.InvalidAllocation, view.free(cells[2]));
        try view.free(next);
    }
}

test "forged and double cell frees preserve the live cell" {
    var memory: [224]u8 align(8) = undefined;
    const view = slab.View.from(&memory, 32, 1).?;
    view.initialize();
    const cell = try view.alloc();
    for (0..5) |field| {
        var bad = cell;
        switch (field) {
            0 => bad.bytes = cell.bytes[1..],
            1 => bad.bytes = cell.bytes[0..31],
            2 => bad.ticket += 1,
            3 => bad.index = std.math.maxInt(u32),
            else => bad.epoch += 1,
        }
        try std.testing.expectError(error.InvalidAllocation, view.free(bad));
    }
    try view.free(cell);
    try std.testing.expectError(error.InvalidAllocation, view.free(cell));
    const next = try view.alloc();
    try std.testing.expectEqual(cell.bytes.ptr, next.bytes.ptr);
    try std.testing.expectError(error.InvalidAllocation, view.free(cell));
    try view.free(next);
}

test "pending slab is inaccessible until initialized and published" {
    var memory: [4096]u8 align(64) = undefined;
    var heap = buddy.Heap.init(&memory, 0).?;
    var table = Table{};
    try std.testing.expect(table.open(key));
    const lease = try table.reserveSlab(&heap, 0, key, 32, 8);
    try std.testing.expectError(error.NotReady, table.allocSlab(0, key, lease));
    @memset(lease.allocation.bytes, 0);
    try std.testing.expectError(error.Corrupt, table.publishSlab(0, key, lease));
    const view = try table.prepareSlab(0, key, lease);
    view.initialize();
    try std.testing.expectError(error.NotReady, table.allocSlab(0, key, lease));
    try table.publishSlab(0, key, lease);
    try std.testing.expectError(error.InvalidAllocation, table.publishSlab(0, key, lease));
    try std.testing.expectError(error.InvalidAllocation, table.prepareSlab(0, key, lease));
    const copy = lease;
    const a = try table.allocSlab(0, key, lease);
    const b = try table.allocSlab(0, key, copy);
    try std.testing.expect(a.bytes.ptr != b.bytes.ptr);
    try table.freeSlab(0, key, copy, a);
    try table.closeSlab(&heap, 0, key, lease);
    try std.testing.expectEqual(heap.payload.len, heap.free_bytes);
}

test "many cells use one quota entry and explicit close releases live children" {
    var memory: [8192]u8 align(64) = undefined;
    var heap = buddy.Heap.init(&memory, 0).?;
    var table = Table{};
    try std.testing.expect(table.open(key));
    const lease = try ready(&table, &heap, key, 32, 32);
    const before = heap.free_bytes;
    for (0..32) |_| _ = try table.allocSlab(0, key, lease);
    try std.testing.expectError(error.OutOfMemory, table.allocSlab(0, key, lease));
    try std.testing.expectEqual(before, heap.free_bytes);
    try std.testing.expectEqual(@as(u32, 1), table.owned());
    try std.testing.expectEqual(@as(u32, 1), heap.allocations);
    const raw = try table.alloc(&heap, 0, key, 8, 8);
    try std.testing.expectError(error.Full, table.reserveSlab(&heap, 0, key, 8, 2));
    try table.closeSlab(&heap, 0, key, lease);
    try table.free(&heap, 0, key, raw);
    try std.testing.expectEqual(heap.payload.len, heap.free_bytes);
}

test "parent epoch rejects an old cell even when address and local ticket recur" {
    var memory: [4096]u8 align(64) = undefined;
    var heap = buddy.Heap.init(&memory, 0).?;
    var table = Table{};
    try std.testing.expect(table.open(key));
    const old = try ready(&table, &heap, key, 32, 4);
    const stale = try table.allocSlab(0, key, old);
    try table.closeSlab(&heap, 0, key, old);
    const next = try ready(&table, &heap, key, 32, 4);
    const current = try table.allocSlab(0, key, next);
    try std.testing.expectEqual(stale.bytes.ptr, current.bytes.ptr);
    try std.testing.expectEqual(stale.ticket, current.ticket);
    try std.testing.expect(stale.epoch != current.epoch);
    try std.testing.expectError(error.InvalidAllocation, table.freeSlab(0, key, next, stale));
    try std.testing.expectError(error.InvalidAllocation, table.allocSlab(0, key, old));
    try table.freeSlab(0, key, next, current);
    try table.closeSlab(&heap, 0, key, next);
}

test "slab ownership kind and forged parent checks precede metadata access" {
    var memory: [8192]u8 align(64) = undefined;
    var heap = buddy.Heap.init(&memory, 0).?;
    var table = Table{};
    const other = resources.Key{ .slot = 1, .generation = 1 };
    try std.testing.expect(table.open(key) and table.open(other));
    const lease = try ready(&table, &heap, key, 32, 4);
    const cell = try table.allocSlab(0, key, lease);
    try std.testing.expectError(error.WrongOwner, table.allocSlab(1, key, lease));
    try std.testing.expectError(error.WrongOwner, table.freeSlab(1, key, lease, cell));
    try std.testing.expectError(error.Inactive, table.allocSlab(0, other, lease));
    try std.testing.expectError(error.Inactive, table.closeSlab(&heap, 0, other, lease));
    var forged = lease;
    forged.allocation.bytes = lease.allocation.bytes[1..];
    try std.testing.expectError(error.InvalidAllocation, table.allocSlab(0, key, forged));
    const fake_pool = Table.Pool{ .key = key, .allocation = lease.allocation };
    try std.testing.expectError(error.InvalidAllocation, table.allocPool(0, key, fake_pool, 1, 1));
    try std.testing.expectError(error.InvalidAllocation, table.closePool(&heap, 0, key, fake_pool));
    const pool = try table.openPool(&heap, 0, key, 128, 8);
    const fake_slab = Table.Slab{ .key = key, .allocation = pool.allocation };
    try std.testing.expectError(error.InvalidAllocation, table.allocSlab(0, key, fake_slab));
    try std.testing.expectError(error.InvalidAllocation, table.closeSlab(&heap, 0, key, fake_slab));
    try table.freeSlab(0, key, lease, cell);
}

test "unfinished initialization and poisoned slabs still reclaim as single parents" {
    for ([_]bool{ false, true }) |published| {
        var memory: [4096]u8 align(64) = undefined;
        var heap = buddy.Heap.init(&memory, 0).?;
        var table = Table{};
        try std.testing.expect(table.open(key));
        const lease = try table.reserveSlab(&heap, 0, key, 32, 4);
        if (published) {
            (try table.prepareSlab(0, key, lease)).initialize();
            try table.publishSlab(0, key, lease);
            _ = try table.allocSlab(0, key, lease);
        }
        @memset(lease.allocation.bytes, 0xcc);
        if (published) try std.testing.expectError(error.Faulted, table.allocSlab(0, key, lease));
        const before = heap.free_bytes;
        try std.testing.expect(table.close(key));
        try std.testing.expectError(error.Inactive, table.allocSlab(0, key, lease));
        try std.testing.expectError(error.Inactive, table.publishSlab(0, key, lease));
        try std.testing.expectEqual(before, heap.free_bytes);
        try std.testing.expect(try table.drainOne(&heap, 0, key));
        try std.testing.expectEqual(@as(u32, 1), table.reclaimed);
        try std.testing.expectEqual(heap.payload.len, heap.free_bytes);
        const next_key = resources.Key{ .slot = 0, .generation = 2 };
        try std.testing.expect(table.open(next_key));
        const next = try ready(&table, &heap, next_key, 32, 4);
        try std.testing.expectError(error.Inactive, table.allocSlab(0, next_key, lease));
        try table.closeSlab(&heap, 0, next_key, next);
    }
}

test "failed slab reservation and cancelled initialization leave no phantom entry" {
    var memory: [4096]u8 align(64) = undefined;
    var heap = buddy.Heap.init(&memory, 0).?;
    var table = Table{};
    try std.testing.expect(table.open(key));
    try std.testing.expectError(error.InvalidRequest, table.reserveSlab(&heap, 0, key, 0, 1));
    try std.testing.expectError(error.OutOfMemory, table.reserveSlab(&heap, 0, key, 32, 60));
    try std.testing.expectError(error.WrongOwner, table.reserveSlab(&heap, 1, key, 32, 4));
    try std.testing.expectEqual(@as(u32, 0), table.owned());
    const lease = try table.reserveSlab(&heap, 0, key, 32, 4);
    try table.closeSlab(&heap, 0, key, lease);
    try std.testing.expectError(error.InvalidAllocation, table.publishSlab(0, key, lease));
    try std.testing.expectEqual(heap.payload.len, heap.free_bytes);
}
