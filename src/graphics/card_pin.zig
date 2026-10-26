//! PIN prompt renderer: accepts only a masked View, never a PIN or Service.
//! Board scanout, cache synchronization, and touch ownership are external.
const std = @import("std");
const input = @import("../card/pin_entry.zig");
const assets = @import("card_pin_assets.zig");
const pixel = @import("test_pattern.zig").rgb565;
pub const width = 720;
pub const height = 1280;
const background = pixel(247, 244, 237);
const foreground = pixel(38, 40, 43);
const muted = pixel(110, 112, 114);
const button = pixel(230, 228, 222);
const accent = pixel(175, 52, 35);

fn Canvas(comptime section: ?[]const u8) type {
    return struct {
        const Self = @This();
        const Store = if (section) |name| struct {
            const masks linksection(name) = assets.masks.*;
            const glyphs linksection(name) = assets.glyphs;
        } else assets;
        bytes: []u8,
        stride: usize,
        left: usize = 0,
        top: usize = 0,
        columns: usize = width,
        rows: usize = height,
        fn put(self: Self, x: usize, y: usize, value: u16) void {
            if (x < self.left or y < self.top or x - self.left >= self.columns or y - self.top >= self.rows) return;
            const offset = (y - self.top) * self.stride + (x - self.left) * 2;
            self.bytes[offset] = @truncate(value);
            self.bytes[offset + 1] = @truncate(value >> 8);
        }
        fn fill(self: Self, rect: input.Rect, color: u16) void {
            const left = @max(rect.x, self.left);
            const right = @min(rect.x + rect.width, self.left + self.columns);
            const top = @max(rect.y, self.top);
            const bottom = @min(rect.y + rect.height, self.top + self.rows);
            if (left >= right or top >= bottom) return;
            for (top..bottom) |y| for (left..right) |x| self.put(x, y, color);
        }
        fn text(self: Self, id: assets.Id, x: usize, y: usize, ink: u16, paper: u16) void {
            const glyph = Store.glyphs[@backingInt(id)];
            var index: usize = 0;
            for (Store.masks[glyph.offset..][0..glyph.length]) |run| {
                const alpha: u16 = run >> 4;
                for (0..@as(usize, run & 15) + 1) |_| {
                    if (alpha != 0) {
                        const r = (((ink >> 11) * alpha + (paper >> 11) * (15 - alpha)) / 15) << 11;
                        const g = ((((ink >> 5) & 63) * alpha + ((paper >> 5) & 63) * (15 - alpha)) / 15) << 5;
                        const b = ((ink & 31) * alpha + (paper & 31) * (15 - alpha)) / 15;
                        self.put(x + index % glyph.width, y + index / glyph.width, r | g | b);
                    }
                    index += 1;
                }
            }
        }
        fn label(self: Self, rect: input.Rect, id: assets.Id, ink: u16, paper: u16) void {
            const glyph = Store.glyphs[@backingInt(id)];
            self.text(id, rect.x + (rect.width - glyph.width) / 2, rect.y + (rect.height - glyph.height) / 2, ink, paper);
        }
    };
}
fn digit(value: u8) assets.Id {
    return switch (value) {
        0 => .d0,
        1 => .d1,
        2 => .d2,
        3 => .d3,
        4 => .d4,
        5 => .d5,
        6 => .d6,
        7 => .d7,
        8 => .d8,
        9 => .d9,
        else => .unknown,
    };
}
pub const paper_color = background;
pub const key_color = button;
pub const accent_color = accent;
pub const dots_rect = input.Rect{ .x = 216, .y = 390, .width = 272, .height = 16 };
pub fn submitRect() input.Rect {
    const g = assets.glyphs[@backingInt(assets.Id.demo_submit)];
    const left = (720 - g.width) / 2;
    return .{ .x = left & ~@as(u16, 3), .y = 1100 + (112 - g.height) / 2, .width = ((left + g.width + 3) & ~@as(u16, 3)) - (left & ~@as(u16, 3)), .height = g.height };
}
pub fn paint(bytes: []u8, stride: usize, view: input.View) bool {
    return paintInternal(null, false, bytes, stride, view);
}
pub fn paintDemo(comptime section: ?[]const u8, bytes: []u8, stride: usize, view: input.View) bool {
    return paintInternal(section, true, bytes, stride, view);
}
pub fn paintDynamic(comptime section: ?[]const u8, dots: []u8, label: []u8, view: input.View) bool {
    const rect = submitRect();
    if (dots.len != dots_rect.width * dots_rect.height * 2 or label.len != @as(usize, rect.width) * rect.height * 2 or
        view.masked_digits > 4 or (view.can_submit and (!view.active or view.masked_digits != 4))) return false;
    const dot_canvas = Canvas(section){ .bytes = dots, .stride = dots_rect.width * 2, .left = dots_rect.x, .top = dots_rect.y, .columns = dots_rect.width, .rows = dots_rect.height };
    dot_canvas.fill(dots_rect, background);
    for (0..4) |index| {
        const left: u16 = @intCast(218 + index * 84);
        dot_canvas.fill(.{ .x = left, .y = 390, .width = 16, .height = 16 }, foreground);
        if (index >= view.masked_digits) dot_canvas.fill(.{ .x = left + 2, .y = 392, .width = 12, .height = 12 }, background);
    }
    const label_canvas = Canvas(section){ .bytes = label, .stride = rect.width * 2, .left = rect.x, .top = rect.y, .columns = rect.width, .rows = rect.height };
    const paper = if (view.can_submit) accent else button;
    const ink = if (view.can_submit) background else muted;
    label_canvas.fill(rect, paper);
    label_canvas.label(input.demoBounds(.submit), .demo_submit, ink, paper);
    return true;
}
fn paintInternal(comptime section: ?[]const u8, comptime demo: bool, bytes: []u8, stride: usize, view: input.View) bool {
    if (stride < width * 2 or stride > std.math.maxInt(usize) / height or bytes.len < stride * height or
        view.masked_digits > 4 or (view.can_submit and (!view.active or view.masked_digits != 4))) return false;
    const canvas = Canvas(section){ .bytes = bytes, .stride = stride };
    canvas.fill(.{ .x = 0, .y = 0, .width = width, .height = height }, background);
    canvas.text(if (demo) .demo_title else .title, 84, 106, foreground, background);
    canvas.text(if (demo) .demo_instruction else .instruction, 84, 190, foreground, background);
    canvas.text(if (demo) .demo_privacy else .privacy, 84, 245, muted, background);
    if (demo) {
        canvas.text(.demo_hint, 84, 300, muted, background);
        for (0..4) |index| {
            const left: u16 = @intCast(218 + index * 84);
            canvas.fill(.{ .x = left, .y = 390, .width = 16, .height = 16 }, foreground);
            if (index >= view.masked_digits) canvas.fill(.{ .x = left + 2, .y = 392, .width = 12, .height = 12 }, background);
        }
    } else {
        canvas.text(.remaining, 84, 300, muted, background);
        canvas.text(if (view.remaining) |count| digit(count) else .unknown, 154, 286, foreground, background);
        canvas.text(.times, 222, 300, muted, background);
        for (0..4) |index| {
            const left: u16 = @intCast(198 + index * 84);
            canvas.fill(.{ .x = left, .y = 366, .width = 56, .height = 64 }, button);
            if (index < view.masked_digits) canvas.fill(.{ .x = left + 20, .y = 390, .width = 16, .height = 16 }, foreground);
        }
    }
    if (!view.active) canvas.text(.disabled, 84, 462, muted, background);
    const keys = [_]input.Key{ .one, .two, .three, .four, .five, .six, .seven, .eight, .nine, .cancel, .zero, .erase, .submit };
    for (keys) |key| {
        const rect = if (demo) input.demoBounds(key) else input.bounds(key);
        const enabled = if (key == .submit) view.can_submit else view.active;
        const paper = if (key == .submit and enabled) accent else button;
        const ink = if (!enabled) muted else if (key == .submit) background else foreground;
        canvas.fill(rect, paper);
        const label: assets.Id = switch (key) {
            .cancel => .cancel,
            .erase => .erase,
            .submit => if (demo) .demo_submit else .submit,
            .zero => .d0,
            .one => .d1,
            .two => .d2,
            .three => .d3,
            .four => .d4,
            .five => .d5,
            .six => .d6,
            .seven => .d7,
            .eight => .d8,
            .nine => .d9,
        };
        canvas.label(rect, label, ink, paper);
    }
    return true;
}
test "PIN renderer rejects invalid geometry/view before writing and preserves row padding" {
    var short: [32]u8 = @splat(0xa5);
    const view = input.View{ .active = true, .masked_digits = 2, .remaining = 3, .can_submit = false };
    try std.testing.expect(!paint(&short, width * 2, view));
    for (short) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
    const stride = width * 2 + 8;
    const frame = try std.testing.allocator.alloc(u8, stride * height);
    defer std.testing.allocator.free(frame);
    @memset(frame, 0xa5);
    try std.testing.expect(paint(frame, stride, view));
    for (0..height) |y| for (frame[y * stride + width * 2 ..][0..8]) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
    var invalid = view;
    invalid.can_submit = true;
    try std.testing.expect(!paint(frame, stride, invalid));
}
