//! A bounded boot arena with no hidden metadata or fallback allocation.
//!
//! Platform code transfers one writable memory span to an arena. Allocation
//! advances monotonically and fails explicitly when the span is exhausted.

const std = @import("std");

pub const Arena = struct {
    memory: []u8,
    cursor: usize = 0,

    pub fn init(memory: []u8) Arena {
        return .{ .memory = memory };
    }

    pub fn alloc(self: *Arena, length: usize, alignment: usize) ?[]u8 {
        if (alignment == 0 or (alignment & (alignment - 1)) != 0) return null;

        const padding_mask = alignment - 1;
        const base = @intFromPtr(self.memory.ptr);
        if (self.cursor > std.math.maxInt(usize) - base) return null;
        const current = base + self.cursor;
        if (current > std.math.maxInt(usize) - padding_mask) return null;
        const aligned_address = (current + padding_mask) & ~padding_mask;
        if (aligned_address < base) return null;
        const start = aligned_address - base;
        if (start > self.memory.len or length > self.memory.len - start) return null;

        const end = start + length;
        self.cursor = end;
        return self.memory[start..end];
    }

    pub fn remaining(self: *const Arena) usize {
        return self.memory.len - self.cursor;
    }

    pub fn reset(self: *Arena) void {
        self.cursor = 0;
    }
};

test "arena aligns allocations and fails closed" {
    var backing: [80]u8 = undefined;
    var arena = Arena.init(backing[0..]);

    const first = arena.alloc(7, 1);
    try std.testing.expect(first != null);
    const aligned = arena.alloc(16, 16);
    try std.testing.expect(aligned != null);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(aligned.?.ptr) % 16);
    try std.testing.expect(arena.alloc(128, 1) == null);
    try std.testing.expect(arena.alloc(1, 3) == null);

    arena.reset();
    try std.testing.expectEqual(backing.len, arena.remaining());
}
