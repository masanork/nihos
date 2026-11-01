//! Bounded native PSRAM stack admission. No guest pointers or memory reads.
const std = @import("std");
pub const Key = struct { slot: u16, generation: u16 };
pub const Binding = struct {
    borrower: Key,
    low: u32,
    high: u32,

    pub fn admit(base: u32, bytes: u32, offset: u32, borrower: Key) ?Binding {
        const stack_bytes = 65536;
        const end = std.math.add(u32, base, bytes) catch return null;
        if (base < 0x48000000 or end > 0x4c000000 or borrower.generation == 0 or
            offset > bytes or stack_bytes > bytes - offset) return null;
        const low = base + offset;
        if (low % 16 != 0) return null;
        return .{ .borrower = borrower, .low = low + 128, .high = low + stack_bytes };
    }
    pub fn accepts(self: Binding, hart: u32, current: Key, mstatus: u32, frame: u32, saved_sp: u32) bool {
        return hart == 0 and current.slot == self.borrower.slot and current.generation == self.borrower.generation and
            mstatus & 0x1800 == 0x1800 and frame % 16 == 0 and frame >= self.low and frame <= self.high and
            128 <= self.high - frame and saved_sp == frame + 128;
    }
};

test "only current generation and complete aligned frames can use a pinned stack" {
    const key: Key = .{ .slot = 2, .generation = 7 };
    const bound = Binding.admit(0x48100000, 512 * 1024, 400 * 1024, key).?;
    try std.testing.expect(bound.accepts(0, key, 0x1880, bound.high - 128, bound.high));
    try std.testing.expect(!bound.accepts(1, key, 0x1880, bound.high - 128, bound.high));
    try std.testing.expect(!bound.accepts(0, .{ .slot = 2, .generation = 8 }, 0x1880, bound.high - 128, bound.high));
    try std.testing.expect(!bound.accepts(0, .{ .slot = 1, .generation = 7 }, 0x1880, bound.high - 128, bound.high));
    try std.testing.expect(!bound.accepts(0, key, 0x80, bound.high - 128, bound.high));
    try std.testing.expect(!bound.accepts(0, key, 0x1880, bound.low - 16, bound.low + 112));
    try std.testing.expect(!bound.accepts(0, key, 0x1880, bound.high - 112, bound.high + 16));
    try std.testing.expect(!bound.accepts(0, key, 0x1880, bound.high - 127, bound.high));
    try std.testing.expect(!bound.accepts(0, key, 0x1880, bound.high - 128, bound.high - 16));
    try std.testing.expect(Binding.admit(0xffff0000, 0x20000, 0, key) == null);
    try std.testing.expect(Binding.admit(0x4ff60000, 65536, 0, key) == null);
    try std.testing.expect(Binding.admit(0x48000000, 65536, 16, key) == null);
    try std.testing.expect(Binding.admit(0x48000000, 65536, 0, .{ .slot = 2, .generation = 0 }) == null);
}
