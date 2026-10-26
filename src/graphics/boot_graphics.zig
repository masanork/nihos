//! Allocation-free boot inscription, independent of the display driver and FS.
//! Progress is a colour animation value, never a boot-completion percentage.
const std = @import("std");
const assets = @import("boot/assets.zig");

pub const width = 720;
pub const height = 1280;
pub const Status = enum(u8) { display = 1, memory, cores, input, ready, failed };
const background = [3]u8{ 17, 17, 17 };
const paper = [3]u8{ 225, 225, 225 };
const muted = [3]u8{ 132, 132, 132 };
const vermilion = [3]u8{ 220, 94, 66 };

fn mix(a: [3]u8, b: [3]u8, amount: u8) [3]u8 {
    var result: [3]u8 = @splat(0);
    for (0..3) |i| result[i] = @intCast((@as(u32, a[i]) * (255 - @as(u32, amount)) + @as(u32, b[i]) * amount + 127) / 255);
    return result;
}

fn rgb565(color: [3]u8) u16 {
    return (@as(u16, color[0] >> 3) << 11) | (@as(u16, color[1] >> 2) << 5) | (color[2] >> 3);
}

fn put(framebuffer: []u8, stride: usize, x: usize, y: usize, color: [3]u8) void {
    const offset = y * stride + x * 2;
    const pixel = rgb565(color);
    framebuffer[offset] = @truncate(pixel);
    framebuffer[offset + 1] = @truncate(pixel >> 8);
}

fn dyeAmount(progress: u8, group: u8) u8 {
    // Three overlapping fades, in reading order; a true monochrome first frame.
    const start = @as(u16, group) * 64;
    const elapsed = @as(u16, progress) -| start;
    return @intCast(@min(elapsed * 255 / 127, 255));
}

/// Paint a portrait 720x1280 scene, centered if the borrowed surface is larger.
/// Invalid geometry is rejected before the first write. Row padding is kept.
/// All text is a compile-time mask; no allocator, font engine, I/O, or clock.
pub fn paintRgb565Le(framebuffer: []u8, surface_width: usize, surface_height: usize, stride: usize, progress: u8, status: Status) bool {
    return paintPlacedRgb565Le(null, framebuffer, surface_width, surface_height, stride, progress, status);
}

/// The native linker can keep immutable lettering in its existing Flash span.
/// The section is a compile-time choice; it never accepts runtime mask data.
pub fn paintPlacedRgb565Le(comptime section: ?[]const u8, framebuffer: []u8, surface_width: usize, surface_height: usize, stride: usize, progress: u8, status: Status) bool {
    const MaskStore = if (section) |name| struct {
        const data linksection(name) = assets.masks.*;
    } else struct {
        const data = assets.masks.*;
    };
    if (surface_width < width or surface_height < height) return false;
    const row_bytes = std.math.mul(usize, surface_width, 2) catch return false;
    const required = std.math.mul(usize, stride, surface_height) catch return false;
    if (stride < row_bytes or framebuffer.len < required) return false;
    const left = (surface_width - width) / 2;
    const top = (surface_height - height) / 2;
    const bg = rgb565(background);
    for (0..surface_height) |y| {
        const row = framebuffer[y * stride ..][0..row_bytes];
        for (0..surface_width) |x| {
            row[x * 2] = @truncate(bg);
            row[x * 2 + 1] = @truncate(bg >> 8);
        }
    }
    for (assets.sprites) |sprite| {
        if (sprite.status != 0 and sprite.status != @backingInt(status)) continue;
        const ink = switch (sprite.ink) {
            .normal => paper,
            .muted => muted,
            .dye => mix(paper, vermilion, dyeAmount(progress, sprite.group)),
            .@"error" => vermilion,
        };
        var pixel: usize = 0;
        for (MaskStore.data[sprite.offset..][0..sprite.length]) |run| {
            const alpha = @as(u8, run >> 4) * 17;
            const count = @as(usize, run & 15) + 1;
            if (alpha != 0) {
                const color = mix(background, ink, alpha);
                for (pixel..pixel + count) |index| {
                    put(framebuffer, stride, left + sprite.x + index % sprite.width, top + sprite.y + index / sprite.width, color);
                }
            }
            pixel += count;
        }
    }
    // A small state marker, not a fictitious percentage or a looping spinner.
    const marker = if (status == .failed) vermilion else mix(muted, vermilion, progress);
    for (0..6) |y| for (0..6) |x| {
        put(framebuffer, stride, left + 92 + x, top + 1166 + y, marker);
    };
    return true;
}

test "embedded masks are bounded and cover precisely each sprite" {
    for (assets.sprites) |sprite| {
        try std.testing.expect(sprite.x + sprite.width <= width);
        try std.testing.expect(sprite.y + sprite.height <= height);
        try std.testing.expect(sprite.offset + sprite.length <= assets.masks.len);
        var decoded: usize = 0;
        for (assets.masks[sprite.offset..][0..sprite.length]) |run| decoded += @as(usize, run & 15) + 1;
        try std.testing.expectEqual(@as(usize, sprite.width) * sprite.height, decoded);
    }
}

test "RGB565 rendering preserves guards and stride padding, rejects overflow" {
    const stride = width * 2 + 8;
    const size = stride * height;
    const guarded = try std.testing.allocator.alloc(u8, size + 32);
    defer std.testing.allocator.free(guarded);
    @memset(guarded, 0xab);
    const pixels = guarded[16..][0..size];
    try std.testing.expect(paintRgb565Le(pixels, width, height, stride, 255, .ready));
    for (guarded[0..16]) |byte| try std.testing.expectEqual(@as(u8, 0xab), byte);
    for (guarded[size + 16 ..]) |byte| try std.testing.expectEqual(@as(u8, 0xab), byte);
    for (0..height) |y| for (pixels[y * stride + width * 2 ..][0..8]) |byte| {
        try std.testing.expectEqual(@as(u8, 0xab), byte);
    };
    var small: [32]u8 = @splat(0xab);
    try std.testing.expect(!paintRgb565Le(&small, width, height, width * 2, 0, .display));
    try std.testing.expect(!paintRgb565Le(&small, std.math.maxInt(usize), height, stride, 0, .display));
    try std.testing.expect(!paintRgb565Le(&small, width, height, std.math.maxInt(usize), 0, .display));
    for (small) |byte| try std.testing.expectEqual(@as(u8, 0xab), byte);
}

test "colour follows reading order and saturates" {
    try std.testing.expectEqual(@as(u8, 0), dyeAmount(0, 0));
    try std.testing.expectEqual(@as(u8, 0), dyeAmount(64, 1));
    try std.testing.expect(dyeAmount(100, 0) > dyeAmount(100, 1));
    try std.testing.expectEqual(@as(u8, 0), dyeAmount(100, 2));
    for (0..3) |group| try std.testing.expectEqual(@as(u8, 255), dyeAmount(255, @intCast(group)));
}

test "only the three 丹穂 pairs and state marker acquire colour" {
    const size = width * height * 2;
    const first = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(first);
    const last = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(last);
    try std.testing.expect(paintRgb565Le(first, width, height, width * 2, 0, .display));
    try std.testing.expect(paintRgb565Le(last, width, height, width * 2, 255, .display));
    var changed: usize = 0;
    for (0..height) |y| for (0..width) |x| {
        const offset = (y * width + x) * 2;
        if (first[offset] == last[offset] and first[offset + 1] == last[offset + 1]) continue;
        const pair = y >= 456 and y < 566 and
            ((x >= 168 and x < 213) or (x >= 256 and x < 301) or (x >= 344 and x < 389));
        const marker = x >= 92 and x < 98 and y >= 1166 and y < 1172;
        try std.testing.expect(pair or marker);
        changed += 1;
    };
    try std.testing.expect(changed > 500);
}
