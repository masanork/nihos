//! Data-only layout for the retained 128 KiB L2 configuration.
const std = @import("std");
pub const Span = struct { start: u32, end: u32 };
pub const tested = [_]Span{ .{ .start = 0x4ff40000, .end = 0x4ff60000 }, .{ .start = 0x4ff6e000, .end = 0x4ffa0000 } };
pub const dma_reserve = Span{ .start = 0x4ff40000, .end = 0x4ff48000 };
pub const stack_reserve = Span{ .start = 0x4ff48000, .end = 0x4ff5a000 };
// A full guard page at each end of both heap spans is never allocated.
pub const heaps = [_]Span{ .{ .start = 0x4ff5b000, .end = 0x4ff5f000 }, .{ .start = 0x4ff6f000, .end = 0x4ff9f000 } };
pub const guards = [_]Span{ .{ .start = 0x4ff5a000, .end = 0x4ff5b000 }, .{ .start = 0x4ff5f000, .end = 0x4ff60000 }, .{ .start = 0x4ff6e000, .end = 0x4ff6f000 }, .{ .start = 0x4ff9f000, .end = 0x4ffa0000 } };
pub const tested_bytes = 328 * 1024;
pub const heap_bytes = 208 * 1024;
pub const guard_bytes = 16 * 1024;
test "high SRAM spans exclude the active stacks ROM and cache" {
    var bytes: u32 = 0;
    for (tested) |span| {
        bytes += span.end - span.start;
        try std.testing.expect(span.start >= 0x4ff40000 and span.end <= 0x4ffa0000);
        try std.testing.expect(span.end <= 0x4ff60000 or span.start >= 0x4ff6e000);
    }
    try std.testing.expectEqual(@as(u32, tested_bytes), bytes);
    var regions: [8]Span = undefined;
    regions[0] = dma_reserve;
    regions[1] = stack_reserve;
    @memcpy(regions[2..4], &heaps);
    @memcpy(regions[4..], &guards);
    var total: u32 = 0;
    for (regions, 0..) |span, index| {
        total += span.end - span.start;
        try std.testing.expect(span.start % 4096 == 0 and span.end % 4096 == 0);
        for (regions[index + 1 ..]) |other| try std.testing.expect(span.end <= other.start or other.end <= span.start);
    }
    try std.testing.expectEqual(@as(u32, tested_bytes), total);
    try std.testing.expectEqual(@as(u32, heap_bytes), heaps[0].end - heaps[0].start + heaps[1].end - heaps[1].start);
}
