//! Independent integer oracle for the compiled single-precision ABI fixture.
const std = @import("std");

/// Positive integer / 16, exactly representable for these small inputs.
pub fn sixteenthsBits(numerator: u16) u32 {
    if (numerator == 0) return 0;
    const value: u32 = numerator;
    const top: u5 = @intCast(31 - @clz(value));
    const exponent = @as(u32, top) + 123;
    return (exponent << 23) | ((value - (@as(u32, 1) << top)) << (23 - top));
}

/// a=(i+1)/4, b=(i+2)/2, c=(i+3)/8; ((a*b)+c)/2.
pub fn mixBits(index: u4) u32 {
    const i: u16 = index;
    return sixteenthsBits((i + 1) * (i + 2) + i + 3);
}

test "compiled FP vectors use an integer oracle with known IEEE values" {
    try std.testing.expectEqual(@as(u32, 0), sixteenthsBits(0));
    try std.testing.expectEqual(@as(u32, 0x3ea0_0000), mixBits(0));
    try std.testing.expectEqual(@as(u32, 0x3fd0_0000), mixBits(3));
    try std.testing.expectEqual(@as(u32, 0x4191_0000), mixBits(15));
    for (0..16) |index| {
        const i: u16 = @intCast(index);
        const reference: f32 = @as(f32, @floatFromInt((i + 1) * (i + 2) + i + 3)) / 16.0;
        try std.testing.expectEqual(@as(u32, @bitCast(reference)), mixBits(@intCast(index)));
    }
}
