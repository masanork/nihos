const std = @import("std");
const buddy = @import("buddy_heap.zig");
const resources = @import("task_resources.zig");
const pool = @import("size_pool.zig");
const Table = resources.Resources(buddy, 2, 2);
const key = resources.Key{ .slot = 0, .generation = 1 };

fn open(table: *Table, heap: *buddy.Heap) !Table.Objects {
    const lease = try table.reserveObjects(heap, 0, key, 2);
    try (try table.prepareObjects(0, key, lease)).initialize();
    try table.publishObjects(0, key, lease);
    return lease;
}

test "pointer lookup proves exact live geometry across every class before reading caller memory" {
    var memory: [131072]u8 align(64) = undefined;
    var heap = buddy.Heap.init(&memory, 0).?;
    var table = Table{};
    try std.testing.expect(table.open(key));
    const lease = try open(&table, &heap);
    for (pool.classes) |size| {
        const object = try table.allocObject(0, key, lease, size - 1);
        const address = @intFromPtr(object.cell.bytes.ptr);
        const found = try table.objectFromPointer(0, key, lease, address);
        try std.testing.expectEqual(object.cell.ticket, found.cell.ticket);
        try std.testing.expectEqual(size - 1, found.cell.bytes.len);
        for ([_]usize{ address - 1, address + 1, address + size - 1 }) |bad| {
            try std.testing.expectError(error.InvalidAllocation, table.objectFromPointer(0, key, lease, bad));
        }
        try table.freeObject(0, key, lease, found);
        try std.testing.expectError(error.InvalidAllocation, table.objectFromPointer(0, key, lease, address));
    }
    for ([_]usize{ 0, 1, std.math.maxInt(usize), @intFromPtr(lease.allocation.bytes.ptr), @intFromPtr(lease.allocation.bytes.ptr) + lease.allocation.bytes.len }) |address| {
        try std.testing.expectError(error.InvalidAllocation, table.objectFromPointer(0, key, lease, address));
    }
}

test "pointer lookup authenticates parent task owner kind and closing state before PSRAM access" {
    var memory: [131072]u8 align(64) = undefined;
    var heap = buddy.Heap.init(&memory, 0).?;
    var table = Table{};
    const other = resources.Key{ .slot = 1, .generation = 1 };
    try std.testing.expect(table.open(key) and table.open(other));
    const lease = try open(&table, &heap);
    const object = try table.allocObject(0, key, lease, 16);
    const address = @intFromPtr(object.cell.bytes.ptr);
    try std.testing.expectError(error.WrongOwner, table.objectFromPointer(1, key, lease, address));
    try std.testing.expectError(error.Inactive, table.objectFromPointer(0, other, lease, address));
    const raw = try table.alloc(&heap, 0, key, 32, 8);
    try std.testing.expectError(error.InvalidAllocation, table.objectFromPointer(0, key, .{ .key = key, .allocation = raw }, address));
    try std.testing.expect(table.close(key));
    try std.testing.expectError(error.Inactive, table.objectFromPointer(0, key, lease, address));
    while (!try table.drainOne(&heap, 0, key)) {}
    try std.testing.expectEqual(heap.payload.len, heap.free_bytes);
    const next = resources.Key{ .slot = 0, .generation = 2 };
    try std.testing.expect(table.open(next));
    try std.testing.expectError(error.Inactive, table.objectFromPointer(0, next, lease, address));
}

test "lookup metadata fault poisons the class but outer task recovery does not inspect it" {
    var memory: [131072]u8 align(64) = undefined;
    var heap = buddy.Heap.init(&memory, 0).?;
    var table = Table{};
    try std.testing.expect(table.open(key));
    const lease = try open(&table, &heap);
    const object = try table.allocObject(0, key, lease, 8);
    const address = @intFromPtr(object.cell.bytes.ptr);
    // Cell cookie occupies the final four bytes immediately before payload.
    const cookie: *u8 = @ptrFromInt(address - 4);
    cookie.* ^= 1;
    try std.testing.expectError(error.Corrupt, table.objectFromPointer(0, key, lease, address));
    try std.testing.expectError(error.Faulted, table.objectFromPointer(0, key, lease, address));
    try std.testing.expect(table.close(key));
    try std.testing.expect(try table.drainOne(&heap, 0, key));
    try std.testing.expectEqual(heap.payload.len, heap.free_bytes);
}

test "C identities distinguish owner slot and generation without truncation or zero aliases" {
    try std.testing.expectEqual(@as(u32, 0), resources.identity(0, .{ .slot = 0, .generation = 0 }));
    try std.testing.expectEqual(@as(u32, 0), resources.identity(256, key));
    try std.testing.expectEqual(@as(u32, 0), resources.identity(0, .{ .slot = 256, .generation = 1 }));
    try std.testing.expectEqual(@as(u32, 0xffffffff), resources.identity(255, .{ .slot = 255, .generation = 65535 }));
    const first = resources.identity(0, key);
    try std.testing.expect(first != 0);
    try std.testing.expect(first != resources.identity(1, key));
    try std.testing.expect(first != resources.identity(0, .{ .slot = 1, .generation = 1 }));
    try std.testing.expect(first != resources.identity(0, .{ .slot = 0, .generation = 2 }));
}
