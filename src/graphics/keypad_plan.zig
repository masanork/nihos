//! Sparse RGB565 scanout plan. Fixed fills avoid reading blank PSRAM pixels.
const std = @import("std");
const screen = @import("card_pin.zig");
pub const Kind = enum(u32) { paper, keys, submit, pixels, dots, label };
pub const Segment = extern struct { kind: Kind, offset: u32 = 0, words: u32, reserved: u32 = 0 };
pub const Config = extern struct {
    plan: u32,
    count: u32,
    peer_start: u32,
    peer_bytes: u32,
    dots_x: u32,
    dots_y: u32,
    dots_width: u32,
    dots_height: u32,
    label_x: u32,
    label_y: u32,
    label_width: u32,
    label_height: u32,
    paper: u32,
    keys: u32,
    accent: u32,
    scratch: u32,
    stride: u32,
    capacity: u32,
};
pub const Error = error{ Malformed, Capacity, UnsupportedBase };
pub const frame_bytes = 720 * 1280 * 2;
pub const frame_words = frame_bytes / 8;
pub const scratch_start: u32 = 0x481f2000;
pub const scratch_end: u32 = 0x48200000;
pub const dots_bytes = screen.dots_rect.width * screen.dots_rect.height * 2;
pub fn labelBytes() usize {
    const r = screen.submitRect();
    return @as(usize, r.width) * r.height * 2;
}
pub fn textureStride() usize {
    return (dots_bytes + labelBytes() + 63) & ~@as(usize, 63);
}
pub fn planAddress() usize {
    return scratch_start + 2 * textureStride();
}
pub fn planCapacity() usize {
    return (scratch_end - planAddress()) / @sizeOf(Segment);
}
const Builder = struct {
    output: []Segment,
    count: usize = 0,
    words: u32 = 0,
    fn add(self: *Builder, kind: Kind, offset: usize, words: usize) Error!void {
        if (words == 0) return;
        if (words > frame_words - self.words or offset > frame_bytes) return error.Malformed;
        self.words += @intCast(words);
        if (self.count > 0 and @backingInt(kind) <= @backingInt(Kind.submit) and self.output[self.count - 1].kind == kind) {
            self.output[self.count - 1].words += @intCast(words);
            return;
        }
        if (self.count == self.output.len) return error.Capacity;
        self.output[self.count] = .{ .kind = kind, .offset = @intCast(offset), .words = @intCast(words) };
        self.count += 1;
    }
};
fn pixel(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | @as(u16, bytes[1]) << 8;
}
fn same(bytes: []const u8, color: u16) bool {
    for (0..4) |i| if (pixel(bytes[i * 2 ..][0..2]) != color) return false;
    return true;
}
pub fn build(frame: []const u8, output: []Segment) Error![]Segment {
    if (frame.len != frame_bytes) return error.Malformed;
    var builder = Builder{ .output = output };
    const label = screen.submitRect();
    const dots = screen.dots_rect;
    for (0..1280) |y| {
        const row = frame[y * 1440 ..][0..1440];
        const base = pixel(row[0..2]);
        if (!same(row[0..8], base)) return error.UnsupportedBase;
        const kind: Kind = if (y >= 1100 and y < 1212) .submit else if (base == screen.paper_color) .paper else if (base == screen.key_color) .keys else return error.UnsupportedBase;
        const forced = if (y >= dots.y and y < dots.y + dots.height) dots else if (y >= label.y and y < label.y + label.height) label else null;
        if (forced) |rect| {
            try builder.add(kind, 0, rect.x / 4);
            try builder.add(if (rect.y == dots.y) .dots else .label, (y - rect.y) * rect.width * 2, rect.width / 4);
            try builder.add(kind, 0, (720 - rect.x - rect.width) / 4);
        } else {
            var left: usize = 0;
            while (left < 180 and same(row[left * 8 ..][0..8], base)) : (left += 1) {}
            if (left == 180) {
                try builder.add(kind, 0, 180);
                continue;
            }
            var right: usize = 180;
            while (right > left and same(row[(right - 1) * 8 ..][0..8], base)) : (right -= 1) {}
            try builder.add(kind, 0, left);
            try builder.add(.pixels, y * 1440 + left * 8, right - left);
            try builder.add(kind, 0, 180 - right);
        }
    }
    if (builder.words != frame_words) return error.Malformed;
    return output[0..builder.count];
}

test "one immutable plan reconstructs every demo count from bounded dynamic textures" {
    const allocator = std.testing.allocator;
    const initial = try allocator.alloc(u8, frame_bytes);
    defer allocator.free(initial);
    const expected = try allocator.alloc(u8, frame_bytes);
    defer allocator.free(expected);
    const replay = try allocator.alloc(u8, frame_bytes);
    defer allocator.free(replay);
    const dots = try allocator.alloc(u8, dots_bytes);
    defer allocator.free(dots);
    const label = try allocator.alloc(u8, labelBytes());
    defer allocator.free(label);
    const segments = try allocator.alloc(Segment, planCapacity());
    defer allocator.free(segments);
    const View = @import("../card/pin_entry.zig").View;
    var view = View{ .active = true, .masked_digits = 0, .remaining = null, .can_submit = false };
    try std.testing.expect(screen.paintDemo(null, initial, 1440, view));
    const plan = try build(initial, segments);
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
                .pixels => @memcpy(target, initial[segment.offset..][0..length]),
                .dots => @memcpy(target, dots[segment.offset..][0..length]),
                .label => @memcpy(target, label[segment.offset..][0..length]),
            }
            offset += length;
        }
        try std.testing.expectEqual(@as(usize, frame_bytes), offset);
        try std.testing.expectEqualSlices(u8, expected, replay);
    }
    try std.testing.expectError(error.Capacity, build(initial, segments[0..1]));
    try std.testing.expectError(error.Malformed, build(initial[0..100], segments));
    try std.testing.expect(planAddress() + planCapacity() * @sizeOf(Segment) <= scratch_end);
}
