//! Diagnostic 80x45 grayscale preview from 1280x720 RAW8 Bayer BGGR.
//! One 2x2 Bayer cell per 16-pixel step; no interpolation or color rendering.
const std = @import("std");
pub const width = 80;
pub const height = 45;
pub const frame_width = 1280;
pub const frame_height = 720;
pub const frame_bytes = frame_width * frame_height;
pub fn row(frame: []const u8, y: usize) ?[width]u8 {
    if (frame.len < frame_bytes or y >= height) return null;
    const base = y * 16 * frame_width;
    var result: [width]u8 = undefined;
    for (&result, 0..) |*pixel, x| {
        const i = base + x * 16;
        const sum = @as(u16, frame[i]) + frame[i + 1] + frame[i + frame_width] + frame[i + frame_width + 1];
        pixel.* = @intCast(sum / 4);
    }
    return result;
}
test "preview samples aligned Bayer cells within the full frame" {
    var frame: [frame_bytes]u8 = @splat(0);
    frame[0] = 4;
    frame[1] = 8;
    frame[frame_width] = 12;
    frame[frame_width + 1] = 16;
    frame[704 * frame_width + 1264] = 200;
    try std.testing.expectEqual(@as(u8, 10), row(&frame, 0).?[0]);
    try std.testing.expectEqual(@as(u8, 50), row(&frame, 44).?[79]);
    try std.testing.expect(row(&frame, 45) == null);
    try std.testing.expect(row(frame[0 .. frame_bytes - 1], 0) == null);
}

/// CPU0-owned diagnostic overlay lifecycle. A dismissal action belongs to the
/// overlay; only later actions are forwarded to the underlying UI model.
pub const Overlay = struct {
    state: enum { idle, visible, repaint_pending, recovery_pending, failed } = .idle,
    dismissal_sequence: u32 = 0,

    pub fn canShow(self: *const Overlay) bool {
        return self.state == .idle;
    }
    /// CPU0 paints synchronously; input cannot interleave with this transition.
    pub fn beginRefresh(self: *Overlay) bool {
        if (self.state != .visible) return false;
        self.state = .idle;
        return true;
    }
    pub fn shown(self: *Overlay) void {
        std.debug.assert(self.canShow());
        self.state = .visible;
    }
    pub fn dismiss(self: *Overlay, sequence: u32) bool {
        if (self.state != .visible) return false;
        self.state = .repaint_pending;
        self.dismissal_sequence = sequence;
        return true;
    }
    pub const Repaint = union(enum) { dismissal: u32, recovery };
    /// Call after any failed attempt that may have touched the framebuffer.
    pub fn failed(self: *Overlay) void {
        std.debug.assert(self.state == .idle);
        self.state = .recovery_pending;
    }
    /// Fatal UI handling may draw an error screen; it must not report the
    /// abandoned ordinary-view repaint as a successful recovery.
    pub fn abandon(self: *Overlay) void {
        self.state = .failed;
    }
    /// Only call after a successful full repaint and presentation.
    pub fn repainted(self: *Overlay) ?Repaint {
        const result: Repaint = switch (self.state) {
            .repaint_pending => .{ .dismissal = self.dismissal_sequence },
            .recovery_pending => .recovery,
            else => return null,
        };
        self.state = .idle;
        return result;
    }
};
/// Stop suppresses the already submitted frame, then permits a new session.
pub const Live = struct {
    state: enum { idle, running, draining } = .idle,
    pub fn start(self: *Live) bool {
        if (self.state != .idle) return false;
        self.state = .running;
        return true;
    }
    pub fn stop(self: *Live) void {
        if (self.state == .running) self.state = .draining;
    }
    /// Full-view cache writeback must wait for the outstanding capture.
    pub fn canRepaint(self: *const Live) bool {
        return self.state != .draining;
    }
    pub fn acceptFrame(self: *Live) bool {
        if (self.state == .draining) {
            self.state = .idle;
            return false;
        }
        return true;
    }
    pub fn end(self: *Live) void {
        self.state = .idle;
    }
};
test "live dismissal defers full-view repaint until the pending frame drains" {
    var live: Live = .{};
    var overlay: Overlay = .{};
    try std.testing.expect(live.start());
    overlay.shown();
    try std.testing.expect(overlay.dismiss(7));
    live.stop();
    try std.testing.expect(!live.canRepaint());
    try std.testing.expect(overlay.state == .repaint_pending);
    try std.testing.expect(!live.acceptFrame());
    try std.testing.expect(live.canRepaint());
    try std.testing.expectEqual(@as(u32, 7), overlay.repainted().?.dismissal);
    try std.testing.expect(overlay.canShow());
    try std.testing.expect(live.start());
    live.stop();
    live.end(); // a failed capture also ends the repaint wait
    try std.testing.expect(live.canRepaint());
}
test "live stop drains one outstanding frame before restart" {
    var live: Live = .{};
    try std.testing.expect(live.start());
    try std.testing.expect(!live.start());
    try std.testing.expect(live.acceptFrame());
    live.stop();
    try std.testing.expect(!live.start());
    try std.testing.expect(!live.acceptFrame());
    try std.testing.expect(live.start());
    live.end();
    try std.testing.expect(live.start());
}
test "refresh cannot bypass dismissal or failure repaint" {
    var overlay: Overlay = .{};
    try std.testing.expect(!overlay.beginRefresh());
    overlay.shown();
    try std.testing.expect(overlay.beginRefresh());
    overlay.shown();
    try std.testing.expect(overlay.dismiss(8));
    try std.testing.expect(!overlay.beginRefresh());
    _ = overlay.repainted();
    overlay.failed();
    try std.testing.expect(!overlay.beginRefresh());
}
test "overlay consumes dismissal and remains pending until repaint" {
    var overlay = Overlay{};
    try std.testing.expect(overlay.canShow());
    try std.testing.expect(!overlay.dismiss(1));
    overlay.shown();
    try std.testing.expect(!overlay.canShow());
    try std.testing.expect(overlay.dismiss(42));
    try std.testing.expect(!overlay.dismiss(43));
    try std.testing.expect(!overlay.canShow());
    try std.testing.expectEqual(@as(u32, 42), overlay.repainted().?.dismissal);
    try std.testing.expect(overlay.canShow());
    try std.testing.expect(overlay.repainted() == null);
}

test "failed preview blocks new previews until full repaint succeeds" {
    var overlay = Overlay{};
    overlay.failed();
    try std.testing.expect(!overlay.canShow());
    try std.testing.expect(!overlay.dismiss(7));
    // A failed repaint never calls repainted and cannot release the overlay.
    try std.testing.expect(!overlay.canShow());
    try std.testing.expectEqual(Overlay.Repaint.recovery, overlay.repainted().?);
    try std.testing.expect(overlay.canShow());
    try std.testing.expect(overlay.repainted() == null);
}

test "fatal UI handling abandons pending recovery and dismissal" {
    var overlay = Overlay{};
    overlay.failed();
    overlay.abandon();
    try std.testing.expect(!overlay.canShow());
    try std.testing.expect(overlay.repainted() == null);
    try std.testing.expect(!overlay.dismiss(1));
    var shown = Overlay{};
    shown.shown();
    try std.testing.expect(shown.dismiss(7));
    shown.abandon();
    try std.testing.expect(shown.repainted() == null);
    try std.testing.expect(!shown.canShow());
}

pub const display_scale: usize = 4;
pub const display_left: usize = (1280 - width * display_scale) / 2;
pub const display_top: usize = (720 - height * display_scale) / 2;
pub const display_width: usize = width * display_scale;
pub const display_height: usize = height * display_scale;
const tone_lut: [256]u8 = lut: {
    @setEvalBranchQuota(100_000);
    var table: [256]u8 = undefined;
    for (&table, 0..) |*out, i| out.* = @intCast(std.math.sqrt(@as(u32, @intCast(i)) * 255));
    break :lut table;
};
/// Optional display-only curve. This does not change captured RAW8 or sensor exposure.
pub fn tone(value: u8, enabled: bool) u8 {
    return if (enabled) tone_lut[value] else value;
}
/// Paint a completed sampled preview in the existing landscape orientation.
/// Caller owns the framebuffer and is responsible for cache/display handoff.
/// The frame contains sampled grayscale, not a demosaiced colour image.
pub fn paint(frame: []u8, pixels: *const [height][width]u8, tone_enabled: bool) bool {
    const physical_width = 720;
    const physical_height = 1280;
    const stride = physical_width * 2;
    if (frame.len < stride * physical_height) return false;
    for (0..display_width) |x| {
        const physical_row = physical_height - 1 - (display_left + x);
        for (0..display_height) |y| {
            const value = tone(pixels[y / display_scale][x / display_scale], tone_enabled);
            const color = (@as(u16, value >> 3) << 11) | (@as(u16, value >> 2) << 5) | @as(u16, value >> 3);
            const offset = physical_row * stride + (display_top + y) * 2;
            frame[offset] = @truncate(color);
            frame[offset + 1] = @truncate(color >> 8);
        }
    }
    return true;
}
/// Compare every displayed pixel against the sampled preview after the caller
/// has completed cache writeback and invalidation. This checks the CPU-visible
/// framebuffer only; it does not observe the panel or scanout DMA contents.
pub fn mismatches(frame: []const u8, pixels: *const [height][width]u8, tone_enabled: bool) ?u32 {
    if (frame.len < 720 * 1280 * 2) return null;
    var errors: u32 = 0;
    for (0..display_width) |x| {
        const physical_row = 1279 - (display_left + x);
        for (0..display_height) |y| {
            const value = tone(pixels[y / display_scale][x / display_scale], tone_enabled);
            const expected = (@as(u16, value >> 3) << 11) | (@as(u16, value >> 2) << 5) | @as(u16, value >> 3);
            const offset = physical_row * 1440 + (display_top + y) * 2;
            const lo: *const volatile u8 = &frame[offset];
            const hi: *const volatile u8 = &frame[offset + 1];
            const actual = @as(u16, lo.*) | (@as(u16, hi.*) << 8);
            if (actual != expected) errors += 1;
        }
    }
    return errors;
}
test "preview renders bounded rotated grayscale RGB565 with correct corners" {
    const bytes = 720 * 1280 * 2;
    const data = try std.testing.allocator.alloc(u8, bytes + 2);
    defer std.testing.allocator.free(data);
    @memset(data, 0x5a);
    var pixels: [height][width]u8 = @splat(@splat(0));
    pixels[0][0] = 255;
    pixels[height - 1][width - 1] = 128;
    try std.testing.expect(!paint(data[1..bytes], &pixels, false));
    try std.testing.expect(paint(data[1 .. bytes + 1], &pixels, false));
    const first = 1 + (1279 - display_left) * 1440 + display_top * 2;
    const last = 1 + (1279 - (display_left + display_width - 1)) * 1440 + (display_top + display_height - 1) * 2;
    try std.testing.expectEqual(@as(u8, 0xff), data[first]);
    try std.testing.expectEqual(@as(u8, 0xff), data[first + 1]);
    try std.testing.expectEqual(@as(u8, 0x10), data[last]);
    try std.testing.expectEqual(@as(u8, 0x84), data[last + 1]);
    try std.testing.expectEqual(@as(u8, 0x5a), data[0]);
    try std.testing.expectEqual(@as(u8, 0x5a), data[bytes + 1]);
    pixels[0][0] = 29;
    try std.testing.expect(paint(data[1 .. bytes + 1], &pixels, true));
    try std.testing.expectEqual(@as(u8, 0xaa), data[first]);
    try std.testing.expectEqual(@as(u8, 0x52), data[first + 1]);
    try std.testing.expectEqual(@as(u8, 29), pixels[0][0]);
    try std.testing.expectEqual(@as(?u32, 0), mismatches(data[1 .. bytes + 1], &pixels, true));
    data[first] ^= 1;
    try std.testing.expectEqual(@as(?u32, 1), mismatches(data[1 .. bytes + 1], &pixels, true));
    try std.testing.expectEqual(@as(?u32, null), mismatches(data[1..bytes], &pixels, true));
}

test "display tone is monotonic, bounded and leaves raw data intact" {
    try std.testing.expectEqual(@as(u8, 0), tone(0, true));
    try std.testing.expectEqual(@as(u8, 255), tone(255, true));
    for (0..255) |i| {
        const value: u8 = @intCast(i);
        try std.testing.expect(tone(value, true) <= tone(value + 1, true));
        try std.testing.expect(tone(value, true) >= value);
        try std.testing.expectEqual(value, tone(value, false));
    }
    try std.testing.expect(tone(29, true) > 29);
}
