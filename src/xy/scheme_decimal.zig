//! Binary64 conversion isolated for placement with the xy foreground code.
const std = @import("std");

pub fn parse(bytes: []const u8) error{Syntax}!f64 {
    return std.fmt.parseFloat(f64, bytes) catch error.Syntax;
}

pub fn format(value: f64, output: []u8) error{TextFull}![]const u8 {
    var scientific: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&scientific, "{e}", .{value}) catch return error.TextFull;
    const e = std.mem.indexOfScalar(u8, s, 'e') orelse return error.TextFull;
    const exponent = std.fmt.parseInt(i32, s[e + 1 ..], 10) catch return error.TextFull;
    if (exponent < -4 or exponent > 15) {
        if (s.len > output.len) return error.TextFull;
        @memcpy(output[0..s.len], s);
        return output[0..s.len];
    }
    const negative = s[0] == '-';
    const start: usize = @intFromBool(negative);
    var digits: [32]u8 = undefined;
    var n: usize = 0;
    for (s[start..e]) |c| if (c != '.') {
        if (n == digits.len) return error.TextFull;
        digits[n] = c;
        n += 1;
    };
    const dot = exponent + 1;
    var tmp: [64]u8 = undefined;
    var pos: usize = 0;
    if (negative) {
        tmp[pos] = '-';
        pos += 1;
    }
    if (dot <= 0) {
        tmp[pos] = '0';
        tmp[pos + 1] = '.';
        pos += 2;
        for (0..@as(usize, @intCast(-dot))) |_| {
            tmp[pos] = '0';
            pos += 1;
        }
    }
    for (digits[0..n], 0..) |c, i| {
        if (dot > 0 and i == @as(usize, @intCast(dot))) {
            tmp[pos] = '.';
            pos += 1;
        }
        tmp[pos] = c;
        pos += 1;
    }
    if (dot > 0 and @as(usize, @intCast(dot)) >= n) {
        for (n..@as(usize, @intCast(dot))) |_| {
            tmp[pos] = '0';
            pos += 1;
        }
        tmp[pos] = '.';
        tmp[pos + 1] = '0';
        pos += 2;
    }
    if (pos > output.len) return error.TextFull;
    @memcpy(output[0..pos], tmp[0..pos]);
    return output[0..pos];
}

pub export fn nih_xy_decimal_parse(ptr: [*]const u8, len: usize, bits: *u64) callconv(.c) i32 {
    const x = parse(ptr[0..len]) catch return 1;
    bits.* = @bitCast(x);
    return 0;
}
pub export fn nih_xy_decimal_format(bits: u64, ptr: [*]u8, len: usize) callconv(.c) i32 {
    const value: f64 = @bitCast(bits);
    const result = format(value, ptr[0..len]) catch return -1;
    return @intCast(result.len);
}

test "binary64 finite values round-trip through decimal" {
    var bits: u64 = 0x8a5cd789635d2dff;
    var buffer: [64]u8 = undefined;
    const edges = [_]u64{ 0, 1, 0x8000000000000000, 0x0010000000000000, 0x7fefffffffffffff, 0x3ff0000000000000 };
    for (edges) |edge| {
        const number: f64 = @bitCast(edge);
        const str = try format(number, &buffer);
        const restored = try parse(str);
        try std.testing.expectEqual(edge, @as(u64, @bitCast(restored)));
    }
    for (0..10000) |_| {
        bits ^= bits << 13;
        bits ^= bits >> 7;
        bits ^= bits << 17;
        const number: f64 = @bitCast(bits);
        if (!std.math.isFinite(number)) continue;
        const str = try format(number, &buffer);
        const restored = try parse(str);
        try std.testing.expectEqual(bits, @as(u64, @bitCast(restored)));
    }
}

test "decimal parser rounds boundaries and halfway cases" {
    const cases = .{
        .{ "9406149299205461e-16", @as(u64, 0x3fee19847b446b21) },
        .{ "1e-23", @as(u64, 0x3b282db34012b251) },
        .{ "2.2250738585072014e-308", @as(u64, 0x0010000000000000) },
        .{ "1.7976931348623157e308", @as(u64, 0x7fefffffffffffff) },
        .{ "4.9406564584124654e-324", @as(u64, 1) },
        .{ "1.00000000000000011102230246251565404236316680908203125", @as(u64, 0x3ff0000000000000) },
    };
    inline for (cases) |case| {
        const x = try parse(case[0]);
        try std.testing.expectEqual(case[1], @as(u64, @bitCast(x)));
    }
}
