//! Allocation-free boot inscription, independent of the display driver and FS.
//! Progress is a colour animation value, never a boot-completion percentage.
const std = @import("std");
const assets = @import("boot/assets.zig");
const Canvas = @import("canvas").Canvas;

pub const width: usize = 720;
pub const height: usize = 1280;
pub const Layout = assets.Layout;
pub const landscape_width: usize = 1280;
pub const landscape_height: usize = 720;

const Point = struct { x: usize, y: usize };
/// Match the keyboard landscape orientation used by MeOS. Scanout stays 720x1280.
fn physical(layout: Layout, x: usize, y: usize) Point {
    return switch (layout) {
        .portrait => .{ .x = x, .y = y },
        .landscape => .{ .x = y, .y = landscape_width - 1 - x },
    };
}
pub const Status = enum(u8) { display = 1, memory, cores, input, ready, failed, storage };
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
    return paint(section, framebuffer, surface_width, surface_height, stride, progress, status, .portrait, .full);
}

/// Recolour only 丹穂 and the marker after the complete first frame exists.
pub fn recolorPlacedRgb565Le(comptime section: ?[]const u8, framebuffer: []u8, surface_width: usize, surface_height: usize, stride: usize, progress: u8, status: Status) bool {
    return paint(section, framebuffer, surface_width, surface_height, stride, progress, status, .portrait, .dye);
}

/// Compose in logical 1280x720 coordinates, then rotate into the panel's buffer.
/// No second framebuffer, panel command changes, or filesystem access is needed.
pub fn paintLandscapePlacedRgb565Le(comptime section: ?[]const u8, framebuffer: []u8, surface_width: usize, surface_height: usize, stride: usize, progress: u8, status: Status) bool {
    return paint(section, framebuffer, surface_width, surface_height, stride, progress, status, .landscape, .full);
}
pub inline fn recolorLandscapePlacedRgb565Le(comptime section: ?[]const u8, framebuffer: []u8, surface_width: usize, surface_height: usize, stride: usize, progress: u8, status: Status) bool {
    return @call(.always_inline, paint, .{ section, framebuffer, surface_width, surface_height, stride, progress, status, .landscape, .dye });
}

/// Update a prepared splash after a milestone changes. Keep the title and
/// inscription intact while DMA reads the same buffer. Replace each status
/// pixel with its final colour, then clear only the obsolete tail. No
/// clear-and-redraw interval is exposed to scanout.
pub inline fn updateLandscapePlacedRgb565Le(comptime section: ?[]const u8, framebuffer: []u8, surface_width: usize, surface_height: usize, stride: usize, progress: u8, status: Status) bool {
    return @call(.always_inline, paint, .{ section, framebuffer, surface_width, surface_height, stride, progress, status, .landscape, .milestone });
}

const Region = struct { x: usize, y: usize, width: usize, height: usize };
fn statusBounds(comptime layout: Layout) Region {
    var result: ?Region = null;
    for (assets.sprites) |sprite| {
        if (sprite.layout != layout or sprite.status == 0) continue;
        if (result) |*r| {
            if (r.x != sprite.x or r.y != sprite.y or r.height != sprite.height)
                @compileError("status masks must share origin and height");
            r.width = @max(r.width, sprite.width);
        } else result = .{ .x = sprite.x, .y = sprite.y, .width = sprite.width, .height = sprite.height };
    }
    return result.?;
}
fn dyeBounds() Region {
    var x0: usize = landscape_width;
    var y0: usize = landscape_height;
    var x1: usize = 0;
    var y1: usize = 0;
    for (assets.sprites) |sprite| {
        if (sprite.layout != .landscape or sprite.ink != .dye) continue;
        x0 = @min(x0, sprite.x);
        y0 = @min(y0, sprite.y);
        x1 = @max(x1, @as(usize, sprite.x) + sprite.width);
        y1 = @max(y1, @as(usize, sprite.y) + sprite.height);
    }
    return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
}
/// Logical rectangles to flush after live landscape updates. The first two
/// cover dye/marker; only a real status change needs the third rectangle.
pub const landscape_damage = [_]Region{
    dyeBounds(), .{ .x = 102, .y = 647, .width = 6, .height = 6 }, statusBounds(.landscape),
};

const Paint = enum { full, dye, milestone };
fn paint(comptime section: ?[]const u8, framebuffer: []u8, surface_width: usize, surface_height: usize, stride: usize, progress: u8, status: Status, layout: Layout, kind: Paint) bool {
    return @call(.always_inline, paintTo, .{ Canvas, section, framebuffer, surface_width, surface_height, stride, progress, status, layout, kind });
}
fn paintTo(comptime Target: type, comptime section: ?[]const u8, framebuffer: []u8, surface_width: usize, surface_height: usize, stride: usize, progress: u8, status: Status, layout: Layout, kind: Paint) bool {
    const MaskStore = if (section) |name| struct {
        const data linksection(name) = assets.masks.*;
    } else struct {
        const data = assets.masks.*;
    };
    if (surface_width < width or surface_height < height) return false;
    const row_bytes = std.math.mul(usize, surface_width, 2) catch return false;
    const required = std.math.mul(usize, stride, surface_height) catch return false;
    if (stride < row_bytes or framebuffer.len < required) return false;
    const canvas = Target.init(framebuffer, surface_width, surface_height, stride) orelse return false;
    const left = (surface_width - width) / 2;
    const top = (surface_height - height) / 2;
    const bg = rgb565(background);
    if (kind == .full) canvas.fillRect(.{ .x = 0, .y = 0, .width = @intCast(surface_width), .height = @intCast(surface_height) }, bg);
    for (assets.sprites) |sprite| {
        if (sprite.layout != layout) continue;
        if (kind == .dye and sprite.ink != .dye) continue;
        if (kind == .milestone and sprite.ink != .dye and sprite.status == 0) continue;
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
            if (alpha != 0 or (kind == .milestone and sprite.status != 0)) {
                const color = rgb565(mix(background, ink, alpha));
                var index = pixel;
                const end = pixel + count;
                while (index < end) {
                    const x = index % sprite.width;
                    const y = index / sprite.width;
                    const span = @min(end - index, sprite.width - x);
                    // A run can cross a glyph row; split before rotating it.
                    const point = physical(layout, sprite.x + x + if (layout == .landscape) span - 1 else 0, sprite.y + y);
                    canvas.fillRect(.{ .x = @intCast(left + point.x), .y = @intCast(top + point.y), .width = @intCast(if (layout == .landscape) 1 else span), .height = @intCast(if (layout == .landscape) span else 1) }, color);
                    index += span;
                }
            }
            pixel += count;
        }
    }
    if (kind == .milestone) {
        // Status masks share an origin/height. Every pixel inside the new
        // mask was written directly, including transparent background runs.
        // Erase only columns outside it, where the final image is background.
        for (assets.sprites) |sprite| {
            if (sprite.layout != layout or sprite.status != @backingInt(status)) continue;
            const label = if (layout == .landscape) comptime statusBounds(.landscape) else comptime statusBounds(.portrait);
            const tail = label.width - sprite.width;
            if (tail != 0) {
                const point = physical(layout, if (layout == .landscape) label.x + label.width - 1 else label.x + sprite.width, label.y);
                canvas.fillRect(.{ .x = @intCast(left + point.x), .y = @intCast(top + point.y), .width = @intCast(if (layout == .landscape) label.height else tail), .height = @intCast(if (layout == .landscape) tail else label.height) }, bg);
            }
        }
    }
    // A small state marker, not a fictitious percentage or a looping spinner.
    const marker = if (status == .failed) vermilion else mix(muted, vermilion, progress);
    const marker_point = physical(layout, if (layout == .landscape) 107 else 92, if (layout == .landscape) 647 else 1166);
    canvas.fillRect(.{ .x = @intCast(left + marker_point.x), .y = @intCast(top + marker_point.y), .width = 6, .height = 6 }, rgb565(marker));
    return true;
}

test "partial recolour matches the full final frame without repainting other lettering" {
    const size = width * height * 2;
    const partial = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(partial);
    const final = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(final);
    try std.testing.expect(paintRgb565Le(partial, width, height, width * 2, 0, .ready));
    try std.testing.expect(recolorPlacedRgb565Le(null, partial, width, height, width * 2, 255, .ready));
    try std.testing.expect(paintRgb565Le(final, width, height, width * 2, 255, .ready));
    try std.testing.expectEqualSlices(u8, final, partial);
}

test "embedded masks are bounded and cover precisely each sprite" {
    for (assets.sprites) |sprite| {
        try std.testing.expect(sprite.x + sprite.width <= (if (sprite.layout == .landscape) landscape_width else width));
        try std.testing.expect(sprite.y + sprite.height <= (if (sprite.layout == .landscape) landscape_height else height));
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

test "keyboard landscape mapping rotates asymmetric corners in the MeOS direction" {
    try std.testing.expectEqual(Point{ .x = 0, .y = 1279 }, physical(.landscape, 0, 0));
    try std.testing.expectEqual(Point{ .x = 0, .y = 0 }, physical(.landscape, 1279, 0));
    try std.testing.expectEqual(Point{ .x = 719, .y = 1279 }, physical(.landscape, 0, 719));
    try std.testing.expectEqual(Point{ .x = 719, .y = 0 }, physical(.landscape, 1279, 719));
}

test "landscape partial dye matches full repaint and preserves stride and guards" {
    const stride = width * 2 + 8;
    const size = stride * height;
    const memory = try std.testing.allocator.alloc(u8, size + 32);
    defer std.testing.allocator.free(memory);
    @memset(memory, 0xab);
    const frame = memory[16..][0..size];
    const final = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(final);
    @memset(final, 0xab);
    try std.testing.expect(paintLandscapePlacedRgb565Le(null, frame, width, height, stride, 0, .ready));
    try std.testing.expect(recolorLandscapePlacedRgb565Le(null, frame, width, height, stride, 255, .ready));
    try std.testing.expect(paintLandscapePlacedRgb565Le(null, final, width, height, stride, 255, .ready));
    try std.testing.expectEqualSlices(u8, final, frame);
    for (memory[0..16]) |byte| try std.testing.expectEqual(@as(u8, 0xab), byte);
    for (memory[size + 16 ..]) |byte| try std.testing.expectEqual(@as(u8, 0xab), byte);
    for (0..height) |y| for (frame[y * stride + width * 2 ..][0..8]) |byte| {
        try std.testing.expectEqual(@as(u8, 0xab), byte);
    };
    var small: [32]u8 = @splat(0xab);
    try std.testing.expect(!paintLandscapePlacedRgb565Le(null, &small, width, height, width * 2, 0, .ready));
    for (small) |byte| try std.testing.expectEqual(@as(u8, 0xab), byte);
}

test "live milestones match full frames without clearing the static splash" {
    const stride = width * 2 + 8;
    const size = stride * height;
    const frame = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(frame);
    const expected = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(expected);
    @memset(frame, 0xab);
    @memset(expected, 0xab);
    try std.testing.expect(paintLandscapePlacedRgb565Le(null, frame, width, height, stride, 0, .display));
    for ([_]Status{ .memory, .cores, .input, .storage, .failed, .ready, .display }) |status| {
        try std.testing.expect(updateLandscapePlacedRgb565Le(null, frame, width, height, stride, 173, status));
        try std.testing.expect(paintLandscapePlacedRgb565Le(null, expected, width, height, stride, 173, status));
        try std.testing.expectEqualSlices(u8, expected, frame);
    }
    // A sentinel inside the static title must survive a milestone update.
    // Final-image equality alone would also pass after a clear-and-redraw.
    const title = physical(.landscape, 100, 220);
    const offset = title.y * stride + title.x * 2;
    frame[offset] = 0xa5;
    frame[offset + 1] = 0x5a;
    try std.testing.expect(updateLandscapePlacedRgb565Le(null, frame, width, height, stride, 255, .ready));
    try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0x5a }, frame[offset..][0..2]);
    for (0..height) |y| try std.testing.expect(std.mem.allEqual(u8, frame[y * stride + width * 2 ..][0..8], 0xab));
    var invalid: [32]u8 = @splat(0xab);
    try std.testing.expect(!updateLandscapePlacedRgb565Le(null, &invalid, width, height, width * 2, 255, .ready));
    try std.testing.expect(std.mem.allEqual(u8, &invalid, 0xab));
}

// A scanout observer sees every drawing span, not only the final screenshot.
// A pixel may retain its old value or acquire its final value; a third colour
// exposes a destructive intermediate frame even if the end result is correct.
const ScanoutObserver = struct {
    canvas: Canvas,
    var before: []const u8 = &.{};
    var after: []const u8 = &.{};
    var invalid_pixels: usize = 0;
    pub fn init(bytes: []u8, w: usize, h: usize, stride: usize) ?ScanoutObserver {
        return .{ .canvas = Canvas.init(bytes, w, h, stride) orelse return null };
    }
    pub fn fillRect(self: ScanoutObserver, rect: @import("canvas").Rect, color: u16) void {
        self.canvas.fillRect(rect, color);
        const stride = self.canvas.target.stride;
        const left: usize = @intCast(rect.x);
        const top: usize = @intCast(rect.y);
        for (top..top + rect.height) |y| for (left..left + rect.width) |x| {
            const offset = y * stride + x * 2;
            const pixel = self.canvas.target.bytes[offset..][0..2];
            if (!std.mem.eql(u8, pixel, before[offset..][0..2]) and !std.mem.eql(u8, pixel, after[offset..][0..2])) invalid_pixels += 1;
        };
    }
};
test "scanout never observes a third colour during any milestone transition" {
    const stride = width * 2 + 8;
    const size = stride * height;
    const before = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(before);
    const after = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(after);
    const visible = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(visible);
    ScanoutObserver.before = before;
    ScanoutObserver.after = after;
    defer {
        ScanoutObserver.before = &.{};
        ScanoutObserver.after = &.{};
    }
    for ([_]Layout{ .portrait, .landscape }) |layout| {
        for (1..8) |from| for (1..8) |to| {
            @memset(before, 0xab);
            @memset(after, 0xab);
            try std.testing.expect(paint(null, before, width, height, stride, 89, @fromBackingInt(@intCast(from)), layout, .full));
            try std.testing.expect(paint(null, after, width, height, stride, 173, @fromBackingInt(@intCast(to)), layout, .full));
            @memcpy(visible, before);
            ScanoutObserver.invalid_pixels = 0;
            try std.testing.expect(paintTo(ScanoutObserver, null, visible, width, height, stride, 173, @fromBackingInt(@intCast(to)), layout, .milestone));
            try std.testing.expectEqual(@as(usize, 0), ScanoutObserver.invalid_pixels);
            try std.testing.expectEqualSlices(u8, after, visible);
        };
    }
}
test "bounded landscape flush spans cover every modified pixel" {
    const size = width * height * 2;
    const before = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(before);
    const after = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(after);
    for ([_]Paint{ .dye, .milestone }) |kind| {
        try std.testing.expect(paint(null, before, width, height, width * 2, 0, .failed, .landscape, .full));
        @memcpy(after, before);
        try std.testing.expect(paint(null, after, width, height, width * 2, 255, if (kind == .dye) .failed else .ready, .landscape, kind));
        var flushed: usize = 0;
        for (landscape_damage, 0..) |box, index| {
            if (kind == .dye and index == 2) continue;
            for (landscape_width - box.x - box.width..landscape_width - box.x) |y| {
                const start = (y * width * 2 + box.y * 2) & ~@as(usize, 63);
                const end = (y * width * 2 + (box.y + box.height) * 2 + 63) & ~@as(usize, 63);
                try std.testing.expect(end <= size);
                flushed += end - start;
            }
        }
        try std.testing.expect(flushed < size / 20);
        for (0..height) |y| for (0..width) |x| {
            const offset = (y * width + x) * 2;
            if (std.mem.eql(u8, before[offset..][0..2], after[offset..][0..2])) continue;
            const logical_x = landscape_width - 1 - y;
            const logical_y = x;
            var covered = false;
            for (landscape_damage, 0..) |box, index| {
                if (kind == .dye and index == 2) continue;
                covered = covered or (logical_x >= box.x and logical_x < box.x + box.width and logical_y >= box.y and logical_y < box.y + box.height);
            }
            try std.testing.expect(covered);
        };
    }
}
