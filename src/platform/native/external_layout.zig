//! Validate full-capacity PSRAM owner ranges after known boot reservations.
const std = @import("std");
pub fn valid(start: u32, length: u32) bool {
    const base: u32 = 0x4800_0000;
    // Existing MMU windows, or those windows plus the complete scanout lease.
    if (start != base + 3 * 65536 and start != base + 2 * 1024 * 1024) return false;
    const reserved = start - base;
    const capacity = std.math.add(u32, length, reserved) catch return false;
    return capacity >= 4 * 1024 * 1024 and capacity <= 64 * 1024 * 1024 and
        capacity & (capacity - 1) == 0 and length >= 2 * 1024 * 1024;
}
test "only complete known-reservation owner ranges are accepted" {
    for ([_]u32{ 4, 8, 16, 32, 64 }) |mib| {
        const capacity = mib * 1024 * 1024;
        try std.testing.expect(valid(0x4803_0000, capacity - 3 * 65536));
        try std.testing.expect(valid(0x4820_0000, capacity - 2 * 1024 * 1024));
        try std.testing.expect(!valid(0x4820_0000, capacity - 2 * 1024 * 1024 - 64));
    }
    try std.testing.expect(!valid(0x4803_0000, std.math.maxInt(u32)));
    try std.testing.expect(!valid(0x4820_0040, 30 * 1024 * 1024));
    try std.testing.expect(!valid(0x4820_0000, 0));
    try std.testing.expect(!valid(0x4803_0000, 2 * 1024 * 1024 - 3 * 65536));
}
