const std = @import("std");
const buddy = @import("buddy_heap.zig");
const Heap = buddy.Heap;

test "heap geometry rejects invalid spans before writing any metadata" {
    var backing: [1024]u8 align(64) = @splat(0xa7);
    try std.testing.expect(Heap.init(backing[1..], 0) == null);
    try std.testing.expect(Heap.init(backing[0..1023], 0) == null);
    try std.testing.expect(Heap.init(backing[0..448], 0) == null);
    try std.testing.expect(Heap.init(&backing, 2) == null);
    for (backing) |byte| try std.testing.expectEqual(@as(u8, 0xa7), byte);
}

test "aligned requests exclude metadata and both guards" {
    var backing: [32768]u8 align(64) = undefined;
    var heap = Heap.init(&backing, 0).?;
    const initial = heap.free_bytes;
    for ([_]usize{ 1, 8, 64, 256, 4096 }) |alignment| {
        const allocation = try heap.alloc(0, 17, alignment);
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(allocation.bytes.ptr) % alignment);
        try std.testing.expect(@intFromPtr(allocation.bytes.ptr) >= @intFromPtr(heap.payload.ptr) + buddy.header_bytes);
        @memset(allocation.bytes, 0x5c);
        try heap.free(0, allocation);
    }
    try std.testing.expectEqual(initial, heap.free_bytes);
    try std.testing.expect(heap.guardsValid());
    try std.testing.expect(heap.max_steps <= 3 * @as(u32, heap.levels) + 2);
}

test "failed requests preserve the tree capacity and ticket" {
    var backing: [4096]u8 align(64) = undefined;
    var heap = Heap.init(&backing, 0).?;
    const before = heap;
    var tree: [256]u8 = undefined;
    @memcpy(tree[0..heap.tree.len], heap.tree);
    for ([_][2]usize{ .{ 0, 1 }, .{ 1, 0 }, .{ 1, 3 }, .{ 1, 131072 }, .{ std.math.maxInt(usize), 64 } }) |request|
        try std.testing.expectError(error.InvalidRequest, heap.alloc(0, request[0], request[1]));
    try std.testing.expectError(error.WrongOwner, heap.alloc(1, 16, 8));
    try std.testing.expectEqual(before.free_bytes, heap.free_bytes);
    try std.testing.expectEqual(before.ticket, heap.ticket);
    try std.testing.expectEqualSlices(u8, tree[0..heap.tree.len], heap.tree);
}

test "fragmentation coalesces back to the exact initial tree" {
    var backing: [8192]u8 align(64) = undefined;
    var heap = Heap.init(&backing, 1).?;
    var tree: [256]u8 = undefined;
    @memcpy(tree[0..heap.tree.len], heap.tree);
    var allocations: [16]buddy.Allocation = undefined;
    for (&allocations) |*allocation| allocation.* = try heap.alloc(1, 160, 16);
    for (0..8) |index| try heap.free(1, allocations[index * 2]);
    const larger = try heap.alloc(1, 1000, 64);
    for (0..8) |index| try heap.free(1, allocations[index * 2 + 1]);
    try heap.free(1, larger);
    try std.testing.expectEqualSlices(u8, tree[0..heap.tree.len], heap.tree);
    try std.testing.expectEqual(heap.payload.len, heap.free_bytes);
    try std.testing.expectEqual(@as(u32, 0), heap.live);
}

test "exhaustion and reverse frees preserve accounting" {
    var backing: [4096]u8 align(64) = undefined;
    var heap = Heap.init(&backing, 0).?;
    var allocations: [64]buddy.Allocation = undefined;
    var count: usize = 0;
    while (heap.free_bytes != 0) : (count += 1) allocations[count] = try heap.alloc(0, 1, 1);
    try std.testing.expectError(error.OutOfMemory, heap.alloc(0, 1, 1));
    while (count != 0) {
        count -= 1;
        try heap.free(0, allocations[count]);
    }
    try std.testing.expectEqual(heap.payload.len, heap.free_bytes);
    try std.testing.expectEqual(heap.allocations, heap.frees);
}

test "wrong owner interior length double and stale frees cannot mutate state" {
    var backing: [4096]u8 align(64) = undefined;
    var heap = Heap.init(&backing, 0).?;
    const old = try heap.alloc(0, 32, 8);
    try std.testing.expectError(error.WrongOwner, heap.free(1, old));
    var bad = old;
    bad.bytes = old.bytes[1..];
    try std.testing.expectError(error.InvalidAllocation, heap.free(0, bad));
    bad = old;
    bad.bytes = old.bytes[0..31];
    try std.testing.expectError(error.InvalidAllocation, heap.free(0, bad));
    try heap.free(0, old);
    try std.testing.expectError(error.InvalidAllocation, heap.free(0, old));
    const next = try heap.alloc(0, 32, 8);
    try std.testing.expectEqual(old.bytes.ptr, next.bytes.ptr);
    const before = heap.free_bytes;
    try std.testing.expectError(error.InvalidAllocation, heap.free(0, old));
    try std.testing.expectEqual(before, heap.free_bytes);
    try heap.free(0, next);
}

test "foreign heap and invalid node handles cannot authorize a header read" {
    var first: [4096]u8 align(64) = undefined;
    var second: [4096]u8 align(64) = undefined;
    var heap = Heap.init(&first, 0).?;
    var other = Heap.init(&second, 0).?;
    const a = try heap.alloc(0, 32, 8);
    const b = try other.alloc(0, 32, 8);
    try std.testing.expectError(error.InvalidAllocation, other.free(0, a));
    for ([_]u32{ 0, 0xffff_ffff }) |node| {
        var bad = a;
        bad.node = node;
        try std.testing.expectError(error.InvalidAllocation, heap.free(0, bad));
    }
    try heap.free(0, a);
    try other.free(0, b);
}

test "corrupt tree and guards poison subsequent operations" {
    var backing: [4096]u8 align(64) = undefined;
    var heap = Heap.init(&backing, 0).?;
    heap.tree[2] = 0x7f;
    try std.testing.expectError(error.Corrupt, heap.alloc(0, 8, 8));
    try std.testing.expectError(error.Faulted, heap.alloc(0, 8, 8));
    heap = Heap.init(&backing, 0).?;
    const a = try heap.alloc(0, 8, 8);
    backing[63] ^= 1;
    try std.testing.expectError(error.Corrupt, heap.free(0, a));
    try std.testing.expectEqual(@as(u32, 1), heap.live);
}

test "forged allocated marker outside payload is rejected without reading there" {
    var backing: [4096]u8 align(64) = undefined;
    var heap = Heap.init(&backing, 0).?;
    heap.tree[1] = 0x80 | heap.levels;
    const bad = buddy.Allocation{ .bytes = backing[0..1], .ticket = 1, .node = 1, .owner = 0 };
    try std.testing.expectError(error.Corrupt, heap.free(0, bad));
}

test "serial exhaustion fails without wrapping into an old ticket" {
    var backing: [4096]u8 align(64) = undefined;
    var heap = Heap.init(&backing, 0).?;
    heap.ticket = std.math.maxInt(u64);
    try std.testing.expectError(error.SerialExhausted, heap.alloc(0, 8, 8));
    try std.testing.expectEqual(heap.payload.len, heap.free_bytes);
}

test "forged wholly free root cannot authorize a block beyond the backing span" {
    var backing: [4096]u8 align(64) = undefined;
    var heap = Heap.init(&backing, 0).?;
    heap.tree[1] = heap.levels + 1;
    heap.tree[2] = heap.levels;
    heap.tree[3] = heap.levels;
    try std.testing.expectError(error.Corrupt, heap.alloc(0, heap.payload.len - buddy.header_bytes - 7, 8));
}

test "isolated free leaves cannot satisfy a larger block until buddies merge" {
    var backing: [4096]u8 align(64) = undefined;
    var heap = Heap.init(&backing, 0).?;
    var allocations: [64]buddy.Allocation = undefined;
    const count = heap.payload.len / 64;
    for (allocations[0..count]) |*allocation| allocation.* = try heap.alloc(0, 32, 8);
    var index: usize = 0;
    while (index < count) : (index += 2) try heap.free(0, allocations[index]);
    try std.testing.expectError(error.OutOfMemory, heap.alloc(0, 48, 8));
    try heap.free(0, allocations[1]);
    const merged = try heap.alloc(0, 48, 8);
    try heap.free(0, merged);
    index = 3;
    while (index < count) : (index += 2) try heap.free(0, allocations[index]);
    try std.testing.expectEqual(heap.payload.len, heap.free_bytes);
}

test "deterministic churn preserves live bytes disjointness and capacity" {
    var backing: [32768]u8 align(64) = undefined;
    var heap = Heap.init(&backing, 0).?;
    var active: [32]?buddy.Allocation = @splat(null);
    var random: u32 = 0x1a29f042;
    for (0..4000) |_| {
        random = random *% 1664525 +% 1013904223;
        const slot = random % active.len;
        if (active[slot]) |allocation| {
            for (allocation.bytes) |byte| try std.testing.expectEqual(@as(u8, @intCast(slot)), byte);
            try heap.free(0, allocation);
            active[slot] = null;
        } else {
            const length = 1 + (random >> 8) % 2048;
            const alignment = @as(usize, 1) << @as(u6, @intCast((random >> 20) % 10));
            const a = heap.alloc(0, length, alignment) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                continue;
            };
            for (active) |other| if (other) |b| {
                const start = @intFromPtr(a.bytes.ptr);
                const end = start + a.bytes.len;
                try std.testing.expect(end <= @intFromPtr(b.bytes.ptr) or start >= @intFromPtr(b.bytes.ptr) + b.bytes.len);
            };
            @memset(a.bytes, @intCast(slot));
            active[slot] = a;
        }
        try std.testing.expect(heap.max_steps <= 3 * @as(u32, heap.levels) + 2);
    }
    for (active, 0..) |entry, slot| if (entry) |a| {
        for (a.bytes) |byte| try std.testing.expectEqual(@as(u8, @intCast(slot)), byte);
        try heap.free(0, a);
    };
    try std.testing.expectEqual(heap.payload.len, heap.free_bytes);
    try std.testing.expectEqual(heap.allocations, heap.frees);
    try std.testing.expect(heap.guardsValid());
}
