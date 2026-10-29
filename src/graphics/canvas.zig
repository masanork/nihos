//! Small, allocation-free RGB565LE canvas. Not an SDL or M5GFX implementation.
const std = @import("std");
const surface = @import("surface");

pub const Rect = struct { x: i32, y: i32, width: u32, height: u32 };
pub const Image = struct { bytes: []const u8, width: u32, height: u32, stride: usize };
pub const Error = error{ InvalidImage, Aliased };
const Bounds = struct { left: i64, top: i64, right: i64, bottom: i64 };
fn bounds(r: Rect) Bounds {
    return .{ .left = r.x, .top = r.y, .right = @as(i64, r.x) + r.width, .bottom = @as(i64, r.y) + r.height };
}
fn intersect(a: Bounds, b: Bounds) Bounds {
    return .{ .left = @max(a.left, b.left), .top = @max(a.top, b.top), .right = @min(a.right, b.right), .bottom = @min(a.bottom, b.bottom) };
}
fn validImage(image: Image, bpp: usize) bool {
    const row = std.math.mul(usize, image.width, bpp) catch return false;
    const length = std.math.mul(usize, image.stride, image.height) catch return false;
    return image.stride >= row and image.bytes.len >= length;
}
fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const x = @intFromPtr(a.ptr);
    const y = @intFromPtr(b.ptr);
    return if (x <= y) y - x < a.len else x - y < b.len;
}

/// The caller owns the buffer and must serialize access for this canvas's lifetime.
pub const Canvas = struct {
    target: surface.Surface,
    clip: Bounds,

    pub fn init(bytes: []u8, width: usize, height: usize, stride: usize) ?Canvas {
        const target = surface.Surface.init(bytes, width, height, stride) orelse return null;
        return .{ .target = target, .clip = .{ .left = 0, .top = 0, .right = @intCast(width), .bottom = @intCast(height) } };
    }
    /// Returns an independent view whose clip intersects the existing clip.
    pub fn clipped(self: Canvas, rect: Rect) Canvas {
        var result = self;
        result.clip = intersect(self.clip, bounds(rect));
        return result;
    }
    pub fn fillRect(self: Canvas, rect: Rect, color: u16) void {
        const r = intersect(self.clip, bounds(rect));
        if (r.left >= r.right or r.top >= r.bottom) return;
        for (@as(usize, @intCast(r.top))..@as(usize, @intCast(r.bottom))) |y| {
            for (@as(usize, @intCast(r.left))..@as(usize, @intCast(r.right))) |x| {
                std.mem.writeInt(u16, self.target.bytes[y * self.target.stride + x * 2 ..][0..2], color, .little);
            }
        }
    }
    /// Move a rectangle within the same surface. Uncovered pixels are unchanged.
    pub fn copyRect(self: Canvas, source: Rect, dest_x: i32, dest_y: i32) void {
        const dx = @as(i64, dest_x) - source.x;
        const dy = @as(i64, dest_y) - source.y;
        const visible_source = intersect(bounds(source), .{ .left = 0, .top = 0, .right = @intCast(self.target.width), .bottom = @intCast(self.target.height) });
        const area = intersect(visible_source, .{ .left = self.clip.left - dx, .top = self.clip.top - dy, .right = self.clip.right - dx, .bottom = self.clip.bottom - dy });
        if (area.left >= area.right or area.top >= area.bottom) return;
        const w: usize = @intCast(area.right - area.left);
        const h: usize = @intCast(area.bottom - area.top);
        for (0..h) |row| {
            const sy: usize = @intCast(if (dy > 0) area.bottom - 1 - @as(i64, @intCast(row)) else area.top + @as(i64, @intCast(row)));
            const ty: usize = @intCast(@as(i64, @intCast(sy)) + dy);
            const sx: usize = @intCast(area.left);
            const tx: usize = @intCast(area.left + dx);
            const from = sy * self.target.stride + sx * 2;
            const to = ty * self.target.stride + tx * 2;
            const byte_count = w * 2;
            const src = self.target.bytes[from..][0..byte_count];
            const dst = self.target.bytes[to..][0..byte_count];
            // Rows in different scanlines do not overlap; horizontal moves may.
            if (to == from) continue;
            if (from + byte_count <= to or to + byte_count <= from) {
                @memcpy(dst, src);
            } else if (to < from) {
                std.mem.copyForwards(u8, dst, src);
            } else {
                std.mem.copyBackwards(u8, dst, src);
            }
        }
    }
    /// One pixel wide, inclusive endpoints; canonical major-axis rounding.
    pub fn line(self: Canvas, x0: i32, y0: i32, x1: i32, y1: i32, color: u16) void {
        if (self.clip.left >= self.clip.right or self.clip.top >= self.clip.bottom) return;
        const ax: i64 = x0;
        const ay: i64 = y0;
        const bx: i64 = x1;
        const by: i64 = y1;
        const horizontal = @abs(bx - ax) >= @abs(by - ay);
        var major0 = if (horizontal) ax else ay;
        var minor0 = if (horizontal) ay else ax;
        var major1 = if (horizontal) bx else by;
        var minor1 = if (horizontal) by else bx;
        if (major0 > major1) {
            std.mem.swap(i64, &major0, &major1);
            std.mem.swap(i64, &minor0, &minor1);
        }
        const lo = @max(major0, if (horizontal) self.clip.left else self.clip.top);
        const hi = @min(major1, (if (horizontal) self.clip.right else self.clip.bottom) - 1);
        if (lo > hi) return;
        const length: i128 = major1 - major0;
        var pos = lo;
        while (pos <= hi) : (pos += 1) {
            const minor: i64 = if (length == 0) minor0 else @intCast(@as(i128, minor0) + @divFloor(@as(i128, minor1 - minor0) * (pos - major0) + @divFloor(length, 2), length));
            const x = if (horizontal) pos else minor;
            const y = if (horizontal) minor else pos;
            if (x < self.clip.left or x >= self.clip.right or y < self.clip.top or y >= self.clip.bottom) continue;
            std.mem.writeInt(u16, self.target.bytes[@as(usize, @intCast(y)) * self.target.stride + @as(usize, @intCast(x)) * 2 ..][0..2], color, .little);
        }
    }
    /// Copies RGB565LE or converts one-byte palette indices to RGB565LE.
    /// Source and palette must not alias any part of the target buffer.
    pub fn blitRgb565(self: Canvas, image: Image, x: i32, y: i32) Error!void {
        try self.copy(image, x, y, null);
    }
    pub fn blitIndexed8(self: Canvas, image: Image, palette: *const [256]u16, x: i32, y: i32) Error!void {
        if (overlaps(self.target.bytes, std.mem.asBytes(palette))) return error.Aliased;
        try self.copy(image, x, y, palette);
    }
    /// Nearest-neighbour indexed image into a destination rectangle.
    pub fn blitIndexed8Scaled(self: Canvas, image: Image, palette: *const [256]u16, dest: Rect) Error!void {
        if (overlaps(self.target.bytes, std.mem.asBytes(palette))) return error.Aliased;
        try self.scale(image, palette, dest);
    }
    /// Nearest-neighbour RGB565LE image into a destination rectangle.
    pub fn blitRgb565Scaled(self: Canvas, image: Image, dest: Rect) Error!void {
        try self.scale(image, null, dest);
    }
    fn scale(self: Canvas, image: Image, palette: ?*const [256]u16, dest: Rect) Error!void {
        const bpp: usize = if (palette == null) 2 else 1;
        if (!validImage(image, bpp) or image.width == 0 or image.height == 0) return error.InvalidImage;
        if (overlaps(self.target.bytes, image.bytes)) return error.Aliased;
        if (dest.width == 0 or dest.height == 0) return;
        const area = intersect(self.clip, bounds(dest));
        if (area.left >= area.right or area.top >= area.bottom) return;
        for (@as(usize, @intCast(area.top))..@as(usize, @intCast(area.bottom))) |dy| {
            const sy: usize = @intCast(@divFloor(@as(u64, @intCast(@as(i64, @intCast(dy)) - dest.y)) * image.height, dest.height));
            for (@as(usize, @intCast(area.left))..@as(usize, @intCast(area.right))) |dx| {
                const sx: usize = @intCast(@divFloor(@as(u64, @intCast(@as(i64, @intCast(dx)) - dest.x)) * image.width, dest.width));
                const source = sy * image.stride + sx * bpp;
                const color = if (palette) |p| p[image.bytes[source]] else std.mem.readInt(u16, image.bytes[source..][0..2], .little);
                std.mem.writeInt(u16, self.target.bytes[dy * self.target.stride + dx * 2 ..][0..2], color, .little);
            }
        }
    }
    fn copy(self: Canvas, image: Image, x: i32, y: i32, palette: ?*const [256]u16) Error!void {
        const bpp: usize = if (palette == null) 2 else 1;
        if (!validImage(image, bpp)) return error.InvalidImage;
        if (overlaps(self.target.bytes, image.bytes)) return error.Aliased;
        const area = intersect(self.clip, bounds(.{ .x = x, .y = y, .width = image.width, .height = image.height }));
        if (area.left >= area.right or area.top >= area.bottom) return;
        if (palette == null) {
            const sx: usize = @intCast(area.left - x);
            const dx: usize = @intCast(area.left);
            const bytes: usize = @intCast((area.right - area.left) * 2);
            for (@as(usize, @intCast(area.top))..@as(usize, @intCast(area.bottom))) |dy| {
                const sy: usize = @intCast(@as(i64, @intCast(dy)) - y);
                const source = sy * image.stride + sx * 2;
                const target = dy * self.target.stride + dx * 2;
                @memcpy(self.target.bytes[target..][0..bytes], image.bytes[source..][0..bytes]);
            }
            return;
        }
        for (@as(usize, @intCast(area.top))..@as(usize, @intCast(area.bottom))) |dy| {
            const sy: usize = @intCast(@as(i64, @intCast(dy)) - y);
            for (@as(usize, @intCast(area.left))..@as(usize, @intCast(area.right))) |dx| {
                const sx: usize = @intCast(@as(i64, @intCast(dx)) - x);
                const source = sy * image.stride + sx * bpp;
                const color = if (palette) |p| p[image.bytes[source]] else std.mem.readInt(u16, image.bytes[source..][0..2], .little);
                std.mem.writeInt(u16, self.target.bytes[dy * self.target.stride + dx * 2 ..][0..2], color, .little);
            }
        }
    }
    /// Uses the existing surface compositor, retaining its encoded RGB565 rounding.
    pub fn blitMask(self: Canvas, mask: Image, x: i32, y: i32, color: u16) Error!void {
        if (!validImage(mask, 1) or mask.width > std.math.maxInt(i32) or mask.height > std.math.maxInt(i32)) return error.InvalidImage;
        if (overlaps(self.target.bytes, mask.bytes)) return error.Aliased;
        const area = intersect(self.clip, bounds(.{ .x = x, .y = y, .width = mask.width, .height = mask.height }));
        if (area.left >= area.right or area.top >= area.bottom) return;
        const dx: usize = @intCast(area.left);
        const dy: usize = @intCast(area.top);
        const sx: usize = @intCast(area.left - x);
        const sy: usize = @intCast(area.top - y);
        const w: usize = @intCast(area.right - area.left);
        const h: usize = @intCast(area.bottom - area.top);
        // Full remaining rows are supplied because Surface validates stride * height.
        const dest = self.target.bytes[dy * self.target.stride ..][0 .. h * self.target.stride];
        const src = mask.bytes[sy * mask.stride ..][0 .. h * mask.stride];
        // A shifted slice lacks trailing padding after the last row; use per-row calls.
        for (0..h) |row| {
            const row_target = surface.Surface.init(dest[row * self.target.stride ..][0..self.target.stride], self.target.width, 1, self.target.stride) orelse return error.InvalidImage;
            const row_mask = surface.Mask{ .bytes = src[row * mask.stride + sx ..][0..w], .width = w, .height = 1, .stride = w };
            if (!row_target.blit(row_mask, @intCast(dx), 0, color)) return error.InvalidImage;
        }
    }
};

test "nested clip and half-open rectangles preserve padding and guards" {
    var bytes: [28]u8 = @splat(0xaa);
    const canvas = Canvas.init(bytes[2..26], 3, 3, 8).?;
    canvas.clipped(.{ .x = 1, .y = 0, .width = 2, .height = 2 }).fillRect(.{ .x = -1, .y = 1, .width = 4, .height = 3 }, 0x1234);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xaa, 0x34, 0x12, 0x34, 0x12, 0xaa, 0xaa }, bytes[10..18]);
    try std.testing.expect(std.mem.allEqual(u8, bytes[0..10], 0xaa));
    try std.testing.expect(std.mem.allEqual(u8, bytes[18..], 0xaa));
}
test "extreme coordinates and invalid geometry are safe" {
    var bytes: [8]u8 = @splat(0);
    try std.testing.expect(Canvas.init(&bytes, 3, 2, 4) == null);
    const c = Canvas.init(&bytes, 2, 2, 4).?;
    c.clipped(.{ .x = std.math.minInt(i32), .y = 0, .width = 1, .height = 1 }).fillRect(.{ .x = 0, .y = 0, .width = 2, .height = 2 }, 0xffff);
    c.fillRect(.{ .x = std.math.maxInt(i32), .y = 0, .width = std.math.maxInt(u32), .height = 2 }, 0xffff);
    try std.testing.expect(std.mem.allEqual(u8, &bytes, 0));
}
test "mask clipping agrees with existing compositor" {
    var expected: [24]u8 = @splat(0x19);
    var actual = expected;
    const mask = [_]u8{ 0, 40, 255, 99, 128, 200, 255, 99 };
    const old = surface.Surface.init(&expected, 3, 3, 8).?;
    try std.testing.expect(old.blit(.{ .bytes = &mask, .width = 3, .height = 2, .stride = 4 }, 0, 1, 0xf800));
    const c = Canvas.init(&actual, 3, 3, 8).?;
    try c.blitMask(.{ .bytes = &mask, .width = 3, .height = 2, .stride = 4 }, 0, 1, 0xf800);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    @memset(&actual, 0x19);
    try c.clipped(.{ .x = 1, .y = 2, .width = 2, .height = 1 }).blitMask(.{ .bytes = &mask, .width = 3, .height = 2, .stride = 4 }, 0, 1, 0xf800);
    try std.testing.expectEqualSlices(u8, expected[18..22], actual[18..22]);
    try std.testing.expect(std.mem.allEqual(u8, actual[0..18], 0x19));
    try std.testing.expect(std.mem.allEqual(u8, actual[22..], 0x19));
}
test "indexed and RGB image copies clip and reject invalid or aliased inputs before writes" {
    var target: [16]u8 = @splat(0xaa);
    const c = Canvas.init(&target, 3, 2, 8).?;
    var palette: [256]u16 = @splat(0);
    palette[1] = 0x1234;
    palette[2] = 0xabcd;
    const indices = [_]u8{ 1, 2, 0, 0xee, 2, 1, 0, 0xee };
    try c.clipped(.{ .x = 0, .y = 0, .width = 2, .height = 2 }).blitIndexed8(.{ .bytes = &indices, .width = 3, .height = 2, .stride = 4 }, &palette, -1, 0);
    try std.testing.expectEqualSlices(u8, &.{ 0xcd, 0xab, 0, 0, 0xaa, 0xaa, 0xaa, 0xaa, 0x34, 0x12, 0, 0, 0xaa, 0xaa, 0xaa, 0xaa }, &target);
    const before = target;
    try std.testing.expectError(error.InvalidImage, c.blitRgb565(.{ .bytes = &indices, .width = 3, .height = 2, .stride = 4 }, 0, 0));
    try std.testing.expectError(error.Aliased, c.blitRgb565(.{ .bytes = target[0..8], .width = 2, .height = 2, .stride = 4 }, 0, 0));
    try std.testing.expectError(error.Aliased, c.blitMask(.{ .bytes = target[0..8], .width = 2, .height = 2, .stride = 4 }, 0, 0, 0));
    try std.testing.expectEqualSlices(u8, &before, &target);
    const rgb = [_]u8{ 0x78, 0x56, 0xef, 0xbe };
    try c.blitRgb565(.{ .bytes = &rgb, .width = 2, .height = 1, .stride = 4 }, 1, 1);
    try std.testing.expectEqualSlices(u8, &rgb, target[10..14]);
}
test "lines are clipped, endpoint order independent and bounded for extreme coordinates" {
    var a: [50]u8 = @splat(0);
    var b = a;
    const c = Canvas.init(&a, 5, 5, 10).?;
    const d = Canvas.init(&b, 5, 5, 10).?;
    c.clipped(.{ .x = 1, .y = 1, .width = 3, .height = 3 }).line(-2, -2, 7, 7, 0xffff);
    d.clipped(.{ .x = 1, .y = 1, .width = 3, .height = 3 }).line(7, 7, -2, -2, 0xffff);
    try std.testing.expectEqualSlices(u8, &a, &b);
    for (0..5) |y| for (0..5) |x| {
        try std.testing.expectEqual(@as(u16, if (x == y and x >= 1 and x <= 3) 0xffff else 0), std.mem.readInt(u16, a[(y * 5 + x) * 2 ..][0..2], .little));
    };
    c.line(std.math.minInt(i32), 2, std.math.maxInt(i32), 2, 0x1234);
    for (0..5) |x| try std.testing.expectEqual(@as(u16, 0x1234), std.mem.readInt(u16, a[(10 + x) * 2 ..][0..2], .little));
}
test "indexed nearest scaling respects clipping and padding" {
    var out: [36]u8 = @splat(0xaa);
    const c = Canvas.init(&out, 4, 3, 12).?;
    var palette: [256]u16 = @splat(0);
    palette[1] = 0x1111;
    palette[2] = 0x2222;
    const pixels = [_]u8{ 1, 2, 2, 1 };
    const img = Image{ .bytes = &pixels, .width = 2, .height = 2, .stride = 2 };
    try c.blitIndexed8Scaled(img, &palette, .{ .x = -1, .y = 0, .width = 4, .height = 3 });
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x11, 0x22, 0x22, 0x22, 0x22, 0xaa, 0xaa }, out[0..8]);
    try std.testing.expectEqualSlices(u8, &.{ 0x22, 0x22, 0x11, 0x11, 0x11, 0x11, 0xaa, 0xaa }, out[24..32]);
    try std.testing.expect(std.mem.allEqual(u8, out[8..12], 0xaa));
    const before = out;
    try std.testing.expectError(error.InvalidImage, c.blitIndexed8Scaled(.{ .bytes = &.{}, .width = 0, .height = 0, .stride = 0 }, &palette, .{ .x = 0, .y = 0, .width = 0, .height = 0 }));
    try std.testing.expectEqualSlices(u8, &before, &out);
}

test "scaled RGB and indexed images agree across clips and ratios" {
    const indices = [_]u8{ 0, 1, 2, 0xee, 3, 4, 5, 0xee };
    const pixels = [_]u8{ 0x11, 0x11, 0x22, 0x22, 0x33, 0x33, 0xee, 0xee, 0x44, 0x44, 0x55, 0x55, 0x66, 0x66, 0xee, 0xee };
    var palette: [256]u16 = @splat(0);
    for (0..6) |i| palette[i] = @intCast((i + 1) * 0x1111);
    const indexed = Image{ .bytes = &indices, .width = 3, .height = 2, .stride = 4 };
    const rgb = Image{ .bytes = &pixels, .width = 3, .height = 2, .stride = 8 };
    const destinations = [_]Rect{
        .{ .x = 0, .y = 0, .width = 3, .height = 2 },
        .{ .x = -2, .y = -1, .width = 9, .height = 7 },
        .{ .x = 1, .y = 1, .width = 1, .height = 1 },
        .{ .x = 4, .y = 2, .width = 0, .height = 7 },
        .{ .x = std.math.maxInt(i32), .y = 0, .width = std.math.maxInt(u32), .height = 1 },
    };
    for (destinations) |dest| {
        var a: [48]u8 = @splat(0xa5);
        var b = a;
        const ca = Canvas.init(&a, 5, 4, 12).?.clipped(.{ .x = 1, .y = 0, .width = 3, .height = 3 });
        const cb = Canvas.init(&b, 5, 4, 12).?.clipped(.{ .x = 1, .y = 0, .width = 3, .height = 3 });
        try ca.blitIndexed8Scaled(indexed, &palette, dest);
        try cb.blitRgb565Scaled(rgb, dest);
        try std.testing.expectEqualSlices(u8, &a, &b);
    }
    var out: [16]u8 = @splat(0xa5);
    const c = Canvas.init(&out, 2, 2, 8).?;
    const dest = Rect{ .x = 0, .y = 0, .width = 2, .height = 2 };
    try std.testing.expectError(error.InvalidImage, c.blitRgb565Scaled(.{ .bytes = &pixels, .width = 3, .height = 2, .stride = 5 }, dest));
    try std.testing.expectError(error.Aliased, c.blitRgb565Scaled(.{ .bytes = out[0..8], .width = 2, .height = 2, .stride = 4 }, dest));
    try std.testing.expect(std.mem.allEqual(u8, &out, 0xa5));
}

test "scaled indexed image matches independent division reference" {
    const pixels = [_]u8{ 1, 2, 3, 0xff, 4, 5, 6, 0xff };
    var palette: [256]u16 = @splat(0);
    for (0..7) |i| palette[i] = @intCast(i * 0x101);
    var prng = std.Random.DefaultPrng.init(0xe33a);
    const random = prng.random();
    for (0..2000) |_| {
        var result: [72]u8 = @splat(0xa5);
        var expected = result;
        const dest = Rect{ .x = random.intRangeAtMost(i32, -8, 6), .y = random.intRangeAtMost(i32, -8, 6), .width = random.intRangeAtMost(u32, 1, 15), .height = random.intRangeAtMost(u32, 1, 15) };
        const clip = Rect{ .x = random.intRangeAtMost(i32, -4, 6), .y = random.intRangeAtMost(i32, -4, 6), .width = random.intRangeAtMost(u32, 0, 10), .height = random.intRangeAtMost(u32, 0, 10) };
        try Canvas.init(&result, 5, 6, 12).?.clipped(clip).blitIndexed8Scaled(.{ .bytes = &pixels, .width = 3, .height = 2, .stride = 4 }, &palette, dest);
        for (0..6) |y| for (0..5) |x| {
            const px: i64 = @intCast(x);
            const py: i64 = @intCast(y);
            if (px < clip.x or px >= @as(i64, clip.x) + clip.width or py < clip.y or py >= @as(i64, clip.y) + clip.height or px < dest.x or px >= @as(i64, dest.x) + dest.width or py < dest.y or py >= @as(i64, dest.y) + dest.height) continue;
            const sx: usize = @intCast(@divFloor((px - dest.x) * 3, dest.width));
            const sy: usize = @intCast(@divFloor((py - dest.y) * 2, dest.height));
            std.mem.writeInt(u16, expected[y * 12 + x * 2 ..][0..2], palette[pixels[sy * 4 + sx]], .little);
        };
        try std.testing.expectEqualSlices(u8, &expected, &result);
    }
}

test "clipped RGB row copies match pixel reference" {
    const source = [_]u8{ 1, 2, 3, 4, 5, 6, 0xee, 0xee, 7, 8, 9, 10, 11, 12, 0xee, 0xee };
    var prng = std.Random.DefaultPrng.init(0x2d67);
    const random = prng.random();
    for (0..2000) |_| {
        var actual: [72]u8 = @splat(0xa5);
        var expected = actual;
        const x0 = random.intRangeAtMost(i32, -5, 6);
        const y0 = random.intRangeAtMost(i32, -5, 6);
        const clip = Rect{ .x = random.intRangeAtMost(i32, -4, 6), .y = random.intRangeAtMost(i32, -4, 6), .width = random.intRangeAtMost(u32, 0, 10), .height = random.intRangeAtMost(u32, 0, 10) };
        try Canvas.init(&actual, 5, 6, 12).?.clipped(clip).blitRgb565(.{ .bytes = &source, .width = 3, .height = 2, .stride = 8 }, x0, y0);
        for (0..6) |y| for (0..5) |x| {
            const px: i64 = @intCast(x);
            const py: i64 = @intCast(y);
            const sx = px - x0;
            const sy = py - y0;
            if (px < clip.x or px >= @as(i64, clip.x) + clip.width or py < clip.y or py >= @as(i64, clip.y) + clip.height or sx < 0 or sx >= 3 or sy < 0 or sy >= 2) continue;
            const from: usize = @intCast(sy * 8 + sx * 2);
            @memcpy(expected[y * 12 + x * 2 ..][0..2], source[from..][0..2]);
        };
        try std.testing.expectEqualSlices(u8, &expected, &actual);
    }
}

test "overlapping scroll preserves source pixels and row padding" {
    var pixels = [_]u8{ 1, 0, 2, 0, 3, 0, 0xaa, 0xaa, 4, 0, 5, 0, 6, 0, 0xaa, 0xaa, 7, 0, 8, 0, 9, 0, 0xaa, 0xaa };
    const c = Canvas.init(&pixels, 3, 3, 8).?;
    c.copyRect(.{ .x = 0, .y = 0, .width = 3, .height = 3 }, 1, 1);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0, 3, 0, 0xaa, 0xaa, 4, 0, 1, 0, 2, 0, 0xaa, 0xaa, 7, 0, 4, 0, 5, 0, 0xaa, 0xaa }, &pixels);
    c.copyRect(.{ .x = 1, .y = 1, .width = 2, .height = 2 }, 0, 0);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0, 3, 0, 0xaa, 0xaa, 4, 0, 5, 0, 2, 0, 0xaa, 0xaa, 7, 0, 4, 0, 5, 0, 0xaa, 0xaa }, &pixels);
    const before = pixels;
    c.clipped(.{ .x = 1, .y = 1, .width = 1, .height = 1 }).copyRect(.{ .x = std.math.minInt(i32), .y = 0, .width = 1, .height = 1 }, std.math.maxInt(i32), 0);
    try std.testing.expectEqualSlices(u8, &before, &pixels);
}

test "copyRect matches immutable source for clipped overlapping moves" {
    var prng = std.Random.DefaultPrng.init(0x9d1826);
    const random = prng.random();
    for (0..2000) |_| {
        var original: [50]u8 = undefined;
        random.bytes(&original);
        var actual = original;
        var expected = original;
        const source = Rect{ .x = random.intRangeAtMost(i32, -4, 6), .y = random.intRangeAtMost(i32, -4, 6), .width = random.intRangeAtMost(u32, 0, 8), .height = random.intRangeAtMost(u32, 0, 8) };
        const clip = Rect{ .x = random.intRangeAtMost(i32, -4, 6), .y = random.intRangeAtMost(i32, -4, 6), .width = random.intRangeAtMost(u32, 0, 8), .height = random.intRangeAtMost(u32, 0, 8) };
        const dx = random.intRangeAtMost(i32, -4, 6);
        const dy = random.intRangeAtMost(i32, -4, 6);
        Canvas.init(&actual, 4, 5, 10).?.clipped(clip).copyRect(source, dx, dy);
        for (0..5) |y| for (0..4) |x| {
            const px: i64 = @intCast(x);
            const py: i64 = @intCast(y);
            const sx = px - dx + source.x;
            const sy = py - dy + source.y;
            if (px < clip.x or px >= @as(i64, clip.x) + clip.width or py < clip.y or py >= @as(i64, clip.y) + clip.height or sx < 0 or sx >= 4 or sy < 0 or sy >= 5 or sx < source.x or sx >= @as(i64, source.x) + source.width or sy < source.y or sy >= @as(i64, source.y) + source.height) continue;
            const from: usize = @intCast(sy * 10 + sx * 2);
            const to = y * 10 + x * 2;
            expected[to] = original[from];
            expected[to + 1] = original[from + 1];
        };
        try std.testing.expectEqualSlices(u8, &expected, &actual);
    }
}

test "editor style scroll and partial redraw equal full repaint" {
    var incremental: [256]u8 = @splat(0);
    var repainted = incremental;
    const a = Canvas.init(&incremental, 8, 16, 16).?;
    const b = Canvas.init(&repainted, 8, 16, 16).?;
    // Four deliberately different rows act as text-line stand-ins.
    for (0..4) |i| a.fillRect(.{ .x = 0, .y = @intCast(i * 4), .width = 8, .height = 4 }, @intCast(i + 1));
    const content = a.clipped(.{ .x = 0, .y = 0, .width = 8, .height = 16 });
    content.copyRect(.{ .x = 0, .y = 4, .width = 8, .height = 12 }, 0, 0);
    content.fillRect(.{ .x = 0, .y = 12, .width = 8, .height = 4 }, 5);
    for (0..4) |i| b.fillRect(.{ .x = 0, .y = @intCast(i * 4), .width = 8, .height = 4 }, @intCast(i + 2));
    try std.testing.expectEqualSlices(u8, &repainted, &incremental);
}

test "large clipped scrolls match immutable source and preserve padding" {
    const width = 49;
    const height = 43;
    const stride = 104;
    var prng = std.Random.DefaultPrng.init(0x1a234567);
    const random = prng.random();
    for (0..250) |_| {
        var original: [stride * height]u8 = undefined;
        random.bytes(&original);
        var actual = original;
        var expected = original;
        const source = Rect{ .x = random.intRangeAtMost(i32, -30, 60), .y = random.intRangeAtMost(i32, -25, 55), .width = random.intRangeAtMost(u32, 0, 80), .height = random.intRangeAtMost(u32, 0, 70) };
        const clip = Rect{ .x = random.intRangeAtMost(i32, -20, 45), .y = random.intRangeAtMost(i32, -20, 40), .width = random.intRangeAtMost(u32, 0, 70), .height = random.intRangeAtMost(u32, 0, 60) };
        const dest_x = random.intRangeAtMost(i32, -30, 60);
        const dest_y = random.intRangeAtMost(i32, -25, 55);
        Canvas.init(&actual, width, height, stride).?.clipped(clip).copyRect(source, dest_x, dest_y);
        for (0..height) |y| for (0..width) |x| {
            const px: i64 = @intCast(x);
            const py: i64 = @intCast(y);
            const sx = px - dest_x + source.x;
            const sy = py - dest_y + source.y;
            if (px < clip.x or px >= @as(i64, clip.x) + clip.width or py < clip.y or py >= @as(i64, clip.y) + clip.height or sx < 0 or sx >= width or sy < 0 or sy >= height or sx < source.x or sx >= @as(i64, source.x) + source.width or sy < source.y or sy >= @as(i64, source.y) + source.height) continue;
            const from: usize = @intCast(sy * stride + sx * 2);
            const to = y * stride + x * 2;
            expected[to] = original[from];
            expected[to + 1] = original[from + 1];
        };
        try std.testing.expectEqualSlices(u8, &expected, &actual);
    }
}
