//! Owner-local, guarded boot allocation. The caller serializes its own core.
//! Ownership checks are kernel invariants, not a memory protection boundary.
const std = @import("std");
const Arena = @import("arena.zig").Arena;

/// Chosen allocation/guard granule; this does not describe a hardware cache.
pub const granule = 64;
pub const core_count = 2;

pub const CoreArena = struct {
    memory: []u8,
    arena: Arena,
    owner: u32,

    pub fn partition(memory: []u8) ?[core_count]CoreArena {
        if (@intFromPtr(memory.ptr) % granule != 0 or memory.len % granule != 0) return null;
        const stride = memory.len / core_count / granule * granule;
        if (stride < 3 * granule) return null;
        var result: [core_count]CoreArena = undefined;
        for (&result, 0..) |*part, core| {
            const span = memory[core * stride .. (core + 1) * stride];
            part.* = .{
                .memory = span,
                .arena = Arena.init(span[granule .. span.len - granule]),
                .owner = @intCast(core),
            };
            for (0..granule) |index| {
                span[index] = part.guardByte(index);
                span[span.len - granule + index] = part.guardByte(index);
            }
        }
        return result;
    }

    pub fn alloc(self: *CoreArena, caller: u32, length: usize, alignment: usize) ?[]u8 {
        if (caller != self.owner or length == 0) return null;
        return self.arena.alloc(length, alignment);
    }

    pub fn remaining(self: *const CoreArena) usize {
        return self.arena.remaining();
    }

    pub fn guardsValid(self: *const CoreArena) bool {
        const bytes: [*]const volatile u8 = self.memory.ptr;
        for (0..granule) |index| {
            if (bytes[index] != self.guardByte(index) or
                bytes[self.memory.len - granule + index] != self.guardByte(index)) return false;
        }
        return true;
    }

    fn guardByte(self: *const CoreArena, index: usize) u8 {
        return @as(u8, @intCast(index)) ^ @as(u8, @intCast(self.owner)) ^ 0xa5;
    }
};

test "partition excludes guards and gives each owner disjoint aligned storage" {
    var memory: [1024]u8 align(granule) = undefined;
    var parts = CoreArena.partition(&memory).?;
    try std.testing.expectEqual(@as(usize, 384), parts[0].remaining());
    try std.testing.expectEqual(@as(usize, 384), parts[1].remaining());
    const first = parts[0].alloc(0, 384, granule).?;
    const second = parts[1].alloc(1, 384, granule).?;
    @memset(first, 0x12);
    @memset(second, 0x34);
    try std.testing.expect(@intFromPtr(first.ptr) + first.len <= @intFromPtr(second.ptr));
    try std.testing.expect(parts[0].alloc(0, 1, 1) == null);
    try std.testing.expect(parts[0].guardsValid() and parts[1].guardsValid());
}

test "foreign core and invalid requests cannot consume local capacity" {
    var memory: [1024]u8 align(granule) = undefined;
    var parts = CoreArena.partition(&memory).?;
    const before = parts[0].remaining();
    try std.testing.expect(parts[0].alloc(1, 16, 16) == null);
    try std.testing.expect(parts[0].alloc(2, 16, 16) == null);
    try std.testing.expect(parts[0].alloc(0, 0, 1) == null);
    try std.testing.expect(parts[0].alloc(0, 16, 0) == null);
    try std.testing.expect(parts[0].alloc(0, 16, 3) == null);
    try std.testing.expect(parts[0].alloc(0, std.math.maxInt(usize), granule) == null);
    try std.testing.expectEqual(before, parts[0].remaining());
}

test "alignment padding is charged to its owner and failed padding is not" {
    var memory: [1024]u8 align(granule) = undefined;
    var parts = CoreArena.partition(&memory).?;
    _ = parts[0].alloc(0, 1, 1).?;
    const aligned = parts[0].alloc(0, 64, 64).?;
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(aligned.ptr) % 64);
    try std.testing.expectEqual(@as(usize, 256), parts[0].remaining());
    try std.testing.expect(parts[0].alloc(0, 257, 64) == null);
    try std.testing.expectEqual(@as(usize, 256), parts[0].remaining());
    try std.testing.expectEqual(@as(usize, 384), parts[1].remaining());
}

test "guard damage at either boundary is detected" {
    var memory: [1024]u8 align(granule) = undefined;
    for ([_]usize{ 0, 63, 448, 511 }) |offset| {
        const parts = CoreArena.partition(&memory).?;
        memory[offset] ^= 1;
        try std.testing.expect(!parts[0].guardsValid());
        try std.testing.expect(parts[1].guardsValid());
    }
}

test "partition refuses unaligned or undersized memory and leaves an odd granule unused" {
    var memory: [1024]u8 align(granule) = undefined;
    try std.testing.expect(CoreArena.partition(memory[1..]) == null);
    try std.testing.expect(CoreArena.partition(memory[0..1023]) == null);
    try std.testing.expect(CoreArena.partition(memory[0..320]) == null);
    const parts = CoreArena.partition(memory[0..960]).?;
    try std.testing.expectEqual(@as(usize, 448), parts[0].memory.len);
    try std.testing.expectEqual(@as(usize, 448), parts[1].memory.len);
}
