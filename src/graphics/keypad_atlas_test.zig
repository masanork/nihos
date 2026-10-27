const std = @import("std");
const atlas = @import("keypad_atlas.zig");
const screen = @import("card_pin.zig");
const sparse = @import("keypad_plan.zig");
const frame_bytes = sparse.frame_bytes;
const dots_bytes = sparse.dots_bytes;
const labelBytes = sparse.labelBytes;
const textureStride = sparse.textureStride;

test "baked Flash atlas reconstructs every demo count with bounded SRAM copies" {
    const allocator = std.testing.allocator;
    const expected = try allocator.alloc(u8, frame_bytes);
    defer allocator.free(expected);
    const replay = try allocator.alloc(u8, frame_bytes);
    defer allocator.free(replay);
    const dots = try allocator.alloc(u8, dots_bytes);
    defer allocator.free(dots);
    const label = try allocator.alloc(u8, labelBytes());
    defer allocator.free(label);
    const View = @import("../card/pin_entry.zig").View;
    var view = View{ .active = true, .masked_digits = 0, .remaining = null, .can_submit = false };
    const plan = atlas.segments(null);
    const pixels = &atlas.Store(null).pixels;
    var upper: usize = 0;
    var lower: usize = 0;
    var consumed: usize = 0;
    for (plan) |span| if (span.kind == .pixels) {
        const length = span.words * 8;
        try std.testing.expectEqual(consumed, span.offset);
        consumed += length;
        if (length <= 188 * 1024 - upper) upper += length else lower += length;
    };
    try std.testing.expectEqual(pixels.len, consumed);
    try std.testing.expect(2 * textureStride() + plan.len * 64 + lower <= 128 * 1024);
    try std.testing.expect(plan.len * 64 < 48 * 1024);
    for (0..5) |count| {
        view.masked_digits = @intCast(count);
        view.can_submit = count == 4;
        try std.testing.expect(screen.paintDemo(null, expected, 1440, view));
        try std.testing.expect(screen.paintDynamic(null, dots, label, view));
        var offset: usize = 0;
        for (plan) |segment| {
            const length = @as(usize, segment.words) * 8;
            const target = replay[offset..][0..length];
            switch (segment.kind) {
                .paper, .keys, .submit => {
                    const color = switch (segment.kind) {
                        .paper => screen.paper_color,
                        .keys => screen.key_color,
                        .submit => if (count == 4) screen.accent_color else screen.key_color,
                        else => unreachable,
                    };
                    for (0..length / 2) |i| {
                        target[i * 2] = @truncate(color);
                        target[i * 2 + 1] = @truncate(color >> 8);
                    }
                },
                .pixels => @memcpy(target, pixels[segment.offset..][0..length]),
                .dots => @memcpy(target, dots[segment.offset..][0..length]),
                .label => @memcpy(target, label[segment.offset..][0..length]),
            }
            offset += length;
        }
        try std.testing.expectEqual(@as(usize, frame_bytes), offset);
        try std.testing.expectEqualSlices(u8, expected, replay);
    }
}
