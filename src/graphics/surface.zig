//! Borrowed RGB565LE surfaces and A8 masks. No allocation, font or driver API.
//! Geometry/alias errors are rejected before writes; clipping is a valid no-op.
const std = @import("std");

pub const Mask = struct { bytes: []const u8, width: usize, height: usize, stride: usize };
pub const Surface = struct {
    bytes: []u8,
    width: usize,
    height: usize,
    stride: usize,

    pub fn init(bytes: []u8, width: usize, height: usize, stride: usize) ?Surface {
        const result = Surface{ .bytes = bytes, .width = width, .height = height, .stride = stride };
        return if (valid(bytes.len, width, height, stride, 2)) result else null;
    }
    pub fn fill(self: Surface, color: u16) bool {
        if (!valid(self.bytes.len, self.width, self.height, self.stride, 2)) return false;
        for (0..self.height) |y| for (0..self.width) |x| self.put(y * self.stride + x * 2, color);
        return true;
    }
    pub fn blit(self: Surface, mask: Mask, x: i32, y: i32, color: u16) bool {
        return self.blitWithMode(mask, x, y, color, .encoded);
    }
    /// Opt-in sRGB-assumed linear-light composition; panel calibration is separate.
    pub fn blitLinear(self: Surface, mask: Mask, x: i32, y: i32, color: u16) bool {
        return self.blitWithMode(mask, x, y, color, .linear_srgb);
    }
    fn blitWithMode(self: Surface, mask: Mask, x: i32, y: i32, color: u16, mode: enum { encoded, linear_srgb }) bool {
        if (!valid(self.bytes.len, self.width, self.height, self.stride, 2) or
            !valid(mask.bytes.len, mask.width, mask.height, mask.stride, 1)) return false;
        const source = @intFromPtr(mask.bytes.ptr);
        const target = @intFromPtr(self.bytes.ptr);
        if (if (source <= target) target - source < mask.bytes.len else source - target < self.bytes.len) return false;
        const left = @max(@as(i64, 0), x);
        const top = @max(@as(i64, 0), y);
        const right = @min(@as(i64, @intCast(self.width)), @as(i64, x) + @as(i64, @intCast(mask.width)));
        const bottom = @min(@as(i64, @intCast(self.height)), @as(i64, y) + @as(i64, @intCast(mask.height)));
        if (left >= right or top >= bottom) return true;
        for (@as(usize, @intCast(top))..@as(usize, @intCast(bottom))) |dy| {
            const sy: usize = @intCast(@as(i64, @intCast(dy)) - y);
            for (@as(usize, @intCast(left))..@as(usize, @intCast(right))) |dx| {
                const sx: usize = @intCast(@as(i64, @intCast(dx)) - x);
                const alpha = mask.bytes[sy * mask.stride + sx];
                if (alpha == 0) continue;
                const offset = dy * self.stride + dx * 2;
                const background = @as(u16, self.bytes[offset]) | (@as(u16, self.bytes[offset + 1]) << 8);
                self.put(offset, if (alpha == 255) color else switch (mode) {
                    .encoded => blend(background, color, alpha),
                    .linear_srgb => blendLinear(background, color, alpha),
                });
            }
        }
        return true;
    }
    fn put(self: Surface, offset: usize, pixel: u16) void {
        self.bytes[offset] = @truncate(pixel);
        self.bytes[offset + 1] = @truncate(pixel >> 8);
    }
};

fn valid(length: usize, width: usize, height: usize, stride: usize, pixel_bytes: usize) bool {
    if (width > std.math.maxInt(i32) or height > std.math.maxInt(i32)) return false;
    const row = std.math.mul(usize, width, pixel_bytes) catch return false;
    const required = std.math.mul(usize, stride, height) catch return false;
    return stride >= row and length >= required;
}
inline fn blend(background: u16, color: u16, alpha: u8) u16 {
    const a: u32 = alpha;
    const r = (((@as(u32, color) >> 11) & 31) * a + ((@as(u32, background) >> 11) & 31) * (255 - a) + 127) / 255;
    const g = (((@as(u32, color) >> 5) & 63) * a + ((@as(u32, background) >> 5) & 63) * (255 - a) + 127) / 255;
    const b = ((@as(u32, color) & 31) * a + (@as(u32, background) & 31) * (255 - a) + 127) / 255;
    return @intCast((r << 11) | (g << 5) | b);
}

// Tables use the sRGB transfer curve, normalized to 16-bit linear light.
// Thresholds are encoded-space rounding boundaries mapped to linear light.
const linear5 = [_]u16{ 0, 164, 352, 625, 992, 1461, 2040, 2734, 3550, 4492, 5565, 6775, 8127, 9623, 11269, 13069, 15026, 17143, 19426, 21877, 24499, 27295, 30270, 33426, 36766, 40292, 44009, 47918, 52022, 56325, 60828, 65535 };
const linear6 = [_]u16{ 0, 81, 161, 244, 345, 466, 609, 776, 965, 1180, 1420, 1687, 1980, 2301, 2651, 3030, 3439, 3879, 4349, 4851, 5386, 5953, 6554, 7189, 7858, 8562, 9302, 10078, 10890, 11739, 12626, 13551, 14513, 15515, 16556, 17636, 18757, 19918, 21120, 22363, 23648, 24974, 26344, 27756, 29211, 30710, 32253, 33840, 35471, 37148, 38870, 40638, 42452, 44312, 46219, 48173, 50174, 52223, 54320, 56465, 58659, 60901, 63193, 65535 };
const threshold5 = [_]u16{ 82, 249, 477, 796, 1213, 1737, 2372, 3126, 4005, 5012, 6153, 7433, 8856, 10427, 12149, 14027, 16064, 18264, 20630, 23166, 25875, 28760, 31825, 35073, 38505, 42127, 45939, 49946, 54149, 58551, 63156 };
const threshold6 = [_]u16{ 40, 121, 201, 292, 403, 535, 690, 868, 1070, 1297, 1550, 1830, 2137, 2473, 2837, 3231, 3655, 4110, 4596, 5115, 5665, 6250, 6867, 7519, 8206, 8928, 9686, 10480, 11310, 12178, 13084, 14027, 15009, 16031, 17091, 18192, 19332, 20514, 21736, 23000, 24306, 25654, 27044, 28478, 29955, 31476, 33041, 34650, 36304, 38004, 39748, 41539, 43376, 45259, 47190, 49167, 51192, 53265, 55386, 57556, 59774, 62041, 64358 };
fn channelLinear(bg: usize, fg: usize, alpha: u8, table: []const u16, thresholds: []const u16) u16 {
    const a: u32 = alpha;
    const value = (@as(u32, table[bg]) * (255 - a) + @as(u32, table[fg]) * a + 127) / 255;
    var lo: usize = 0;
    var hi = thresholds.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (value >= thresholds[mid]) lo = mid + 1 else hi = mid;
    }
    return @intCast(lo);
}
fn blendLinear(background: u16, color: u16, alpha: u8) u16 {
    const r = channelLinear((background >> 11) & 31, (color >> 11) & 31, alpha, &linear5, &threshold5);
    const g = channelLinear((background >> 5) & 63, (color >> 5) & 63, alpha, &linear6, &threshold6);
    const b = channelLinear(background & 31, color & 31, alpha, &linear5, &threshold5);
    return (r << 11) | (g << 5) | b;
}

test "linear light blend has expected midtone and preserves endpoints" {
    var bytes = [_]u8{ 0, 0, 0, 0, 0, 0 };
    const surface = Surface.init(&bytes, 3, 1, 6).?;
    const mask = [_]u8{ 0, 128, 255 };
    try std.testing.expect(surface.blitLinear(.{ .bytes = &mask, .width = 3, .height = 1, .stride = 3 }, 0, 0, 0xffff));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0xd7, 0xbd, 0xff, 0xff }, &bytes);
}
test "linear light preserves any identical RGB565 color" {
    for (0..65536) |pixel| {
        try std.testing.expectEqual(@as(u16, @intCast(pixel)), blendLinear(@intCast(pixel), @intCast(pixel), 128));
    }
}

test "coverage endpoints and half blend preserve stride and guards" {
    var bytes: [16]u8 = @splat(0xaa);
    const surface = Surface.init(bytes[2..14], 3, 1, 12).?;
    try std.testing.expect(surface.fill(0x001f));
    const mask = [_]u8{ 0, 128, 255 };
    try std.testing.expect(surface.blit(.{ .bytes = &mask, .width = 3, .height = 1, .stride = 3 }, 0, 0, 0xf800));
    try std.testing.expectEqualSlices(u8, &.{ 0x1f, 0, 0x0f, 0x80, 0, 0xf8 }, bytes[2..8]);
    try std.testing.expect(std.mem.allEqual(u8, bytes[8..], 0xaa));
    try std.testing.expectEqual(@as(u8, 0xaa), bytes[0]);
}
test "negative placement clips source rows and fully outside masks do nothing" {
    var bytes: [12]u8 = @splat(0);
    const surface = Surface.init(&bytes, 2, 2, 6).?;
    const mask = [_]u8{ 0, 0, 77, 0, 255, 99 };
    try std.testing.expect(surface.blit(.{ .bytes = &mask, .width = 2, .height = 2, .stride = 3 }, -1, -1, 0xffff));
    try std.testing.expectEqualSlices(u8, &.{ 255, 255 }, bytes[0..2]);
    try std.testing.expect(std.mem.allEqual(u8, bytes[2..], 0));
    const saved = bytes;
    try std.testing.expect(surface.blit(.{ .bytes = &mask, .width = 2, .height = 2, .stride = 3 }, std.math.maxInt(i32), 0, 1));
    try std.testing.expectEqualSlices(u8, &saved, &bytes);
}
test "invalid geometry and aliased masks fail before mutation" {
    var bytes: [16]u8 = @splat(0x55);
    try std.testing.expect(Surface.init(&bytes, std.math.maxInt(usize), 2, 8) == null);
    const surface = Surface.init(&bytes, 2, 2, 8).?;
    try std.testing.expect(!surface.blit(.{ .bytes = bytes[0..1], .width = 1, .height = 1, .stride = 1 }, 0, 0, 0));
    const mask = [_]u8{255};
    try std.testing.expect(!surface.blit(.{ .bytes = &mask, .width = 2, .height = 2, .stride = 2 }, 0, 0, 0));
    try std.testing.expect(std.mem.allEqual(u8, &bytes, 0x55));
}

test "linear light channel matches independent sRGB reference" {
    const Ref = struct {
        fn decode(v: f64) f64 {
            return if (v <= 0.04045) v / 12.92 else std.math.pow(f64, (v + 0.055) / 1.055, 2.4);
        }
        fn encode(v: f64) f64 {
            return if (v <= 0.0031308) 12.92 * v else 1.055 * std.math.pow(f64, v, 1.0 / 2.4) - 0.055;
        }
    };
    inline for (.{ 31, 63 }) |maximum| {
        const table: []const u16 = if (maximum == 31) &linear5 else &linear6;
        const thresholds: []const u16 = if (maximum == 31) &threshold5 else &threshold6;
        for (0..maximum + 1) |bg| for (0..maximum + 1) |fg| {
            for ([_]u8{ 1, 32, 64, 128, 192, 254 }) |alpha| {
                const a = @as(f64, @floatFromInt(alpha)) / 255.0;
                const limit: f64 = @floatFromInt(maximum);
                const light = Ref.decode(@as(f64, @floatFromInt(bg)) / limit) * (1 - a) + Ref.decode(@as(f64, @floatFromInt(fg)) / limit) * a;
                const expected: i32 = @intFromFloat(@round(Ref.encode(light) * limit));
                const actual: i32 = channelLinear(bg, fg, alpha, table, thresholds);
                try std.testing.expect(@abs(actual - expected) <= 1);
            }
        };
    }
}
