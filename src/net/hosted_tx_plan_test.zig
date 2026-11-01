const std = @import("std");
const plan = @import("hosted_tx_plan.zig");
const sdio = @import("../soc/esp32p4/sdio.zig");

test "one long Hosted packet maps to one C6 buffer and one block-mode CMD53" {
    for ([_]struct { logical: usize, blocks: u16 }{
        .{ .logical = 513, .blocks = 2 },
        .{ .logical = 1024, .blocks = 2 },
        .{ .logical = 1025, .blocks = 3 },
        .{ .logical = 1254, .blocks = 3 }, // 12 Hosted + 1242 Ethernet.
        .{ .logical = 1536, .blocks = 3 },
    }) |case| {
        const result = try plan.longPacket(case.logical);
        try std.testing.expectEqual(case.logical, result.logical);
        try std.testing.expectEqual(case.blocks, result.blocks);
        try std.testing.expectEqual(@as(usize, case.blocks) * 512, result.wire);
        try std.testing.expectEqual(plan.fifo_end - @as(u32, @intCast(case.logical)), result.fifo_address);
        try std.testing.expectEqual(@as(u8, 1), result.credits);
        const argument = try sdio.argument53Blocks(result.fifo_address, result.blocks, true);
        try std.testing.expectEqual(@as(u32, case.blocks), argument & 511);
        try std.testing.expect(argument & (1 << 27) != 0);
        try std.testing.expectEqual(result.fifo_address, (argument >> 9) & 0x1ffff);
    }
    try std.testing.expectError(error.InvalidLength, plan.longPacket(512));
    try std.testing.expectError(error.InvalidLength, plan.longPacket(1537));
    try std.testing.expectError(error.InvalidArgument, sdio.argument53Blocks(0, 0, true));
    try std.testing.expectError(error.InvalidArgument, sdio.argument53Blocks(0, 4, true));
}
