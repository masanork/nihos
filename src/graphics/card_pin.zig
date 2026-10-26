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

const Canvas = struct {
    bytes: []u8,
    stride: usize,
    fn put(self: Canvas, x: usize, y: usize, value: u16) void {
        const offset = y * self.stride + x * 2;
        self.bytes[offset] = @truncate(value);
        self.bytes[offset + 1] = @truncate(value >> 8);
    }
    fn fill(self: Canvas, rect: input.Rect, color: u16) void {
        for (rect.y..rect.y + rect.height) |y| for (rect.x..rect.x + rect.width) |x| self.put(x, y, color);
    }
    fn text(self: Canvas, id: assets.Id, x: usize, y: usize, ink: u16, paper: u16) void {
        const glyph = assets.glyphs[@backingInt(id)];
        var index: usize = 0;
        for (assets.masks[glyph.offset..][0..glyph.length]) |run| {
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
    fn label(self: Canvas, rect: input.Rect, id: assets.Id, ink: u16, paper: u16) void {
        const glyph = assets.glyphs[@backingInt(id)];
        self.text(id, rect.x + (rect.width - glyph.width) / 2, rect.y + (rect.height - glyph.height) / 2, ink, paper);
    }
};
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
pub fn paint(bytes: []u8, stride: usize, view: input.View) bool {
    if (stride < width * 2 or stride > std.math.maxInt(usize) / height or bytes.len < stride * height or
        view.masked_digits > 4 or (view.can_submit and (!view.active or view.masked_digits != 4))) return false;
    const canvas = Canvas{ .bytes = bytes, .stride = stride };
    canvas.fill(.{ .x = 0, .y = 0, .width = width, .height = height }, background);
    canvas.text(.title, 84, 106, foreground, background);
    canvas.text(.instruction, 84, 190, foreground, background);
    canvas.text(.privacy, 84, 245, muted, background);
    canvas.text(.remaining, 84, 300, muted, background);
    canvas.text(if (view.remaining) |count| digit(count) else .unknown, 154, 286, foreground, background);
    canvas.text(.times, 222, 300, muted, background);
    for (0..4) |index| {
        const left: u16 = @intCast(198 + index * 84);
        canvas.fill(.{ .x = left, .y = 366, .width = 56, .height = 64 }, button);
        if (index < view.masked_digits) canvas.fill(.{ .x = left + 20, .y = 390, .width = 16, .height = 16 }, foreground);
    }
    if (!view.active) canvas.text(.disabled, 84, 462, muted, background);
    const keys = [_]input.Key{ .one, .two, .three, .four, .five, .six, .seven, .eight, .nine, .cancel, .zero, .erase, .submit };
    for (keys) |key| {
        const rect = input.bounds(key);
        const enabled = if (key == .submit) view.can_submit else view.active;
        const paper = if (key == .submit and enabled) accent else button;
        const ink = if (!enabled) muted else if (key == .submit) background else foreground;
        canvas.fill(rect, paper);
        const label: assets.Id = switch (key) {
            .cancel => .cancel,
            .erase => .erase,
            .submit => .submit,
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
