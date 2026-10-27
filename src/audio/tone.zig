//! Bounded, read-only mono test tone duplicated into 16-bit stereo frames.
const std = @import("std");
pub const rate = 16_000;
pub const frames_per_block = 256;
pub const blocks = 32;
pub const block_bytes = frames_per_block * 4;
pub const frame_count = frames_per_block * blocks;
pub const duration_us = frame_count * 1_000_000 / rate;
pub const Descriptor = extern struct { control: u32, buffer: u32, next: u32, padding: u32 = 0 };
pub const descriptor_bytes = blocks * @sizeOf(Descriptor);

pub fn fill(bytes: *[block_bytes]u8) void {
    const period = [_]i16{ 0, 200, 392, 569, 724, 851, 946, 1004, 1024, 1004, 946, 851, 724, 569, 392, 200, 0, -200, -392, -569, -724, -851, -946, -1004, -1024, -1004, -946, -851, -724, -569, -392, -200 };
    for (0..frames_per_block) |frame| {
        // Smooth both block boundaries; repetition is a diagnostic sound,
        // not a claim of a calibrated sine generator.
        const envelope: i32 = @intCast(@min(frame, frames_per_block - frame, 31));
        const value: i16 = if (frame == frames_per_block - 1) 0 else @intCast(@divTrunc(@as(i32, period[frame % period.len]) * envelope, 31));
        std.mem.writeInt(i16, bytes[frame * 4 ..][0..2], value, .little);
        std.mem.writeInt(i16, bytes[frame * 4 + 2 ..][0..2], value, .little);
    }
}
pub fn descriptors(destination: *[blocks]Descriptor, base: u32, pcm: u32) error{InvalidMemory}!void {
    if (base % 64 != 0 or pcm % 64 != 0 or base < 0x4ff00000 or pcm < 0x4ff00000 or
        @as(u64, base) + descriptor_bytes > 0x4ff28000 or @as(u64, pcm) + block_bytes > 0x4ff28000 or
        (base < pcm + block_bytes and pcm < base + descriptor_bytes)) return error.InvalidMemory;
    for (destination, 0..) |*descriptor, index| descriptor.* = .{
        .control = (1 << 31) | (if (index == blocks - 1) @as(u32, 1) << 30 else 0) | (block_bytes << 12) | block_bytes,
        .buffer = pcm,
        .next = if (index == blocks - 1) 0 else base + @as(u32, @intCast((index + 1) * @sizeOf(Descriptor))),
    };
}
test "audio tone is bounded, DC-balanced stereo with silent boundaries" {
    var bytes: [block_bytes]u8 = undefined;
    fill(&bytes);
    var sum: i32 = 0;
    for (0..frames_per_block) |frame| {
        const left = std.mem.readInt(i16, bytes[frame * 4 ..][0..2], .little);
        try std.testing.expectEqual(left, std.mem.readInt(i16, bytes[frame * 4 + 2 ..][0..2], .little));
        try std.testing.expect(@abs(@as(i32, left)) <= 1024);
        sum += left;
    }
    try std.testing.expect(@abs(sum) < 1024);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, bytes[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, bytes[block_bytes - 4 ..]);
    try std.testing.expectEqual(@as(u32, 512_000), duration_us);
}
test "finite audio descriptors terminate, retain ownership, and reject aliases and PSRAM" {
    var chain: [blocks]Descriptor = undefined;
    try descriptors(&chain, 0x4ff10000, 0x4ff11000);
    for (chain, 0..) |descriptor, index| {
        try std.testing.expect(descriptor.control & (1 << 31) != 0);
        try std.testing.expectEqual(@as(u32, block_bytes), descriptor.control & 0xfff);
        try std.testing.expectEqual(@as(u32, block_bytes), (descriptor.control >> 12) & 0xfff);
        try std.testing.expectEqual(index == blocks - 1, descriptor.control & (1 << 30) != 0);
    }
    try std.testing.expectEqual(@as(u32, 0), chain[blocks - 1].next);
    for ([_][2]u32{ .{ 0x4ff10001, 0x4ff11000 }, .{ 0x4ff10000, 0x4ff10040 }, .{ 0x4ff10000, 0x48000000 }, .{ 0xfffffff0, 0x4ff11000 } }) |addresses| {
        try std.testing.expectError(error.InvalidMemory, descriptors(&chain, addresses[0], addresses[1]));
    }
}
